extends RefCounted
## Tuya local protocol (versions 3.3, 3.4 and 3.5) in pure GDScript.
## One TCP connection per command: connect, negotiate a session key if needed,
## send, read the reply, close. Bulbs only allow one client at a time anyway.

const PORT := 6668
const PREFIX_55AA := 0x000055AA
const SUFFIX_55AA := 0x0000AA55
const PREFIX_6699 := 0x00006699
const SUFFIX_6699 := 0x00009966

const SESS_KEY_NEG_START := 3
const SESS_KEY_NEG_RESP := 4
const SESS_KEY_NEG_FINISH := 5
const CONTROL := 7
const DP_QUERY := 10
const CONTROL_NEW := 13
const DP_QUERY_NEW := 16
const REQ_DEVINFO := 0x25

## Key every Tuya device uses for its UDP broadcasts: md5("yGAdlopoPVldABfn").
static var UDP_KEY: PackedByteArray = "yGAdlopoPVldABfn".md5_buffer()

var id: String
var ip: String
var version: String
var real_key: PackedByteArray
var key: PackedByteArray  # session key once negotiated (3.4+), else the local key
var seq := 1
var tcp: StreamPeerTCP
var rx := PackedByteArray()
var busy := false
var timeout_ms := 4000


func _init(dev_id: String, local_key: String, address: String, ver: String) -> void:
	id = dev_id
	ip = address
	version = ver
	real_key = local_key.to_utf8_buffer()
	key = real_key


## Sends {"dp": value, ...}. Returns "" on success or an error message.
func set_dps(dps: Dictionary) -> String:
	var err: String = await _open()
	if err:
		return err
	var t := int(Time.get_unix_time_from_system())
	var body: Dictionary
	var cmd := CONTROL
	if version == "3.3":
		body = {"devId": id, "uid": id, "t": str(t), "dps": dps}
	else:
		body = {"protocol": 5, "t": t, "data": {"dps": dps}}
		cmd = CONTROL_NEW
	_send(cmd, JSON.stringify(body).to_utf8_buffer())
	var reply = await _recv(cmd)
	_close()
	if reply == null:
		return "The bulb didn't answer. Check that its version and key are right."
	return ""


## Returns the bulb's current {"dp": value} map, or null.
func get_dps():
	if await _open():
		return null
	var cmd := DP_QUERY if version == "3.3" else DP_QUERY_NEW
	var body := {"gwId": id, "devId": id, "uid": id, "t": str(int(Time.get_unix_time_from_system()))}
	_send(cmd, JSON.stringify(body if version == "3.3" else {}).to_utf8_buffer())
	var reply = await _recv(-1)
	_close()
	if reply == null:
		return null
	var data = JSON.parse_string(reply[1].get_string_from_utf8())
	if data is Dictionary:
		if data.has("dps"):
			return data["dps"]
		if data.get("data") is Dictionary and data["data"].has("dps"):
			return data["data"]["dps"]
	return null


# --- connection ---------------------------------------------------------------

func _open() -> String:
	# one command at a time: wait for any previous one to finish
	while busy:
		await Engine.get_main_loop().process_frame
	busy = true
	tcp = StreamPeerTCP.new()
	rx.clear()
	key = real_key
	if tcp.connect_to_host(ip, PORT) != OK:
		_close()
		return "Couldn't connect to the bulb at " + ip
	var deadline := Time.get_ticks_msec() + 3000
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		await Engine.get_main_loop().process_frame
		tcp.poll()
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_close()
		return "Couldn't connect to the bulb at " + ip
	if version != "3.3" and not await _negotiate():
		_close()
		return "The bulb refused the key. Check local_key and version."
	return ""


func _close() -> void:
	if tcp:
		tcp.disconnect_from_host()
	tcp = null
	busy = false


func _negotiate() -> bool:
	var crypto := Crypto.new()
	var local_nonce := crypto.generate_random_bytes(16)
	_send(SESS_KEY_NEG_START, local_nonce)
	var resp = await _recv(SESS_KEY_NEG_RESP)
	if resp == null or resp[1].size() < 48:
		return false
	var remote_nonce: PackedByteArray = resp[1].slice(0, 16)
	if resp[1].slice(16, 48) != hmac_sha256(real_key, local_nonce):
		return false
	_send(SESS_KEY_NEG_FINISH, hmac_sha256(real_key, remote_nonce))
	var mixed := PackedByteArray()
	for i in 16:
		mixed.append(local_nonce[i] ^ remote_nonce[i])
	if version == "3.4":
		key = aes_ecb(real_key, mixed, true)
	else:
		key = gcm_encrypt(real_key, local_nonce.slice(0, 12), mixed, PackedByteArray())[0]
	return true


func _send(cmd: int, payload: PackedByteArray) -> void:
	var needs_header := cmd == CONTROL or cmd == CONTROL_NEW
	var ver_header := version.to_ascii_buffer() + PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	var frame: PackedByteArray
	if version == "3.3":
		var enc := aes_ecb(key, pkcs7(payload), true)
		frame = pack_55aa(seq, cmd, ver_header + enc if needs_header else enc, PackedByteArray())
	elif version == "3.4":
		var plain := ver_header + payload if needs_header else payload
		frame = pack_55aa(seq, cmd, aes_ecb(key, pkcs7(plain), true), key)
	else:
		frame = pack_6699(seq, cmd, ver_header + payload if needs_header else payload, key)
	seq += 1
	tcp.put_data(frame)


## Waits for a frame (with `want_cmd`, or any data frame when -1).
## Returns [cmd, decrypted payload] or null on timeout.
func _recv(want_cmd: int):
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return null  # the bulb hung up, usually because the key is wrong
		var avail := tcp.get_available_bytes()
		if avail > 0:
			var got := tcp.get_partial_data(avail)
			if got[0] == OK:
				rx.append_array(got[1])
		var frame = _take_frame()
		if frame == null:
			await Engine.get_main_loop().process_frame
			continue
		var payload := _decrypt(frame[0], frame[1])
		if want_cmd == -1:
			if payload.size() > 0 and payload[0] == 0x7B:  # '{'
				return [frame[0], payload]
		elif frame[0] == want_cmd:
			return [frame[0], payload]
	return null


## Pops one complete frame off the receive buffer: [cmd, raw payload] or null.
func _take_frame():
	var info = parse_frame(rx, 36 if version == "3.4" else 8)
	if info == null:
		return null
	rx = rx.slice(info[2])
	return [info[0], info[1]]


func _decrypt(cmd: int, raw: PackedByteArray) -> PackedByteArray:
	if raw.is_empty():
		return raw
	var p := raw
	if version == "3.5":
		var r = gcm_decrypt(key, p.slice(0, 12), p.slice(12), PackedByteArray())
		p = r.slice(4)  # retcode
	elif version == "3.4":
		p = unpad(aes_ecb(key, p, false))
	if p.size() >= 15 and p.slice(0, 3) == version.to_ascii_buffer():
		p = p.slice(15)
	if version == "3.3" and p.size() % 16 == 0 and p.size() > 0 and p[0] != 0x7B:
		p = unpad(aes_ecb(key, p, false))
	return p


# --- framing --------------------------------------------------------------------

static func pack_55aa(seqno: int, cmd: int, payload: PackedByteArray, hmac_key: PackedByteArray) -> PackedByteArray:
	var end_len := 36 if hmac_key.size() else 8
	var head := be32(PREFIX_55AA) + be32(seqno) + be32(cmd) + be32(payload.size() + end_len)
	var data := head + payload
	var check := hmac_sha256(hmac_key, data) if hmac_key.size() else be32(crc32(data))
	return data + check + be32(SUFFIX_55AA)


static func pack_6699(seqno: int, cmd: int, payload: PackedByteArray, gcm_key: PackedByteArray) -> PackedByteArray:
	var iv := Crypto.new().generate_random_bytes(12)
	var head := be32(PREFIX_6699) + PackedByteArray([0, 0]) + be32(seqno) + be32(cmd) + be32(payload.size() + 28)
	var enc = gcm_encrypt(gcm_key, iv, payload, head.slice(4))
	return head + iv + enc[0] + enc[1] + be32(SUFFIX_6699)


## Parses one frame at the start of `buf` (skipping junk before a prefix).
## Returns [cmd, payload, bytes_consumed] or null if incomplete. For 55AA frames the
## payload has the retcode and trailer stripped; for 6699 it is iv+ciphertext.
static func parse_frame(buf: PackedByteArray, trailer_len: int):
	var start := 0
	while start + 4 <= buf.size():
		var p := read32(buf, start)
		if p == PREFIX_55AA:
			if buf.size() < start + 16:
				return null
			var length := read32(buf, start + 12)
			var total := 16 + length
			if buf.size() < start + total:
				return null
			var cmd := read32(buf, start + 8)
			# trailer is CRC (4) or HMAC (32) plus the 4-byte suffix; body starts after the retcode
			return [cmd, buf.slice(start + 20, start + total - trailer_len), start + total]
		if p == PREFIX_6699:
			if buf.size() < start + 18:
				return null
			var length := read32(buf, start + 14)
			var total := 18 + length + 4
			if buf.size() < start + total:
				return null
			var cmd := read32(buf, start + 10)
			# iv(12) + ciphertext; the 16-byte tag before the suffix is dropped
			return [cmd, buf.slice(start + 18, start + total - 20), start + total]
		start += 1
	return null


# --- discovery ------------------------------------------------------------------

## Decodes a UDP broadcast from a Tuya device: {"gwId", "ip", "version", ...} or null.
static func decode_broadcast(pkt: PackedByteArray):
	if pkt.size() < 20:
		return null
	var text := ""
	var prefix := read32(pkt, 0)
	if prefix == PREFIX_55AA:
		var length := read32(pkt, 12)
		if pkt.size() < 16 + length:
			return null
		var body := pkt.slice(20, 16 + length - 8)
		if body.size() > 0 and body[0] == 0x7B:
			text = body.get_string_from_utf8()
		elif body.size() % 16 == 0:
			text = unpad(aes_ecb(UDP_KEY, body, false)).get_string_from_utf8()
	elif prefix == PREFIX_6699:
		var length := read32(pkt, 14)
		if pkt.size() < 18 + length:
			return null
		var iv := pkt.slice(18, 30)
		var ct := pkt.slice(30, 18 + length - 16)
		var plain := gcm_decrypt(UDP_KEY, iv, ct, PackedByteArray())
		if plain.size() > 4 and plain[0] != 0x7B and plain[4] == 0x7B:
			plain = plain.slice(4)
		while plain.size() > 0 and plain[-1] == 0:  # the app sometimes pads with NULs
			plain.resize(plain.size() - 1)
		text = plain.get_string_from_utf8()
	var data = JSON.parse_string(text) if text else null
	return data if data is Dictionary else null


## The packet that asks v3.5 devices to announce themselves (sent to UDP port 7000).
static func devinfo_request(my_ip: String) -> PackedByteArray:
	return pack_6699(0, REQ_DEVINFO, JSON.stringify({"from": "app", "ip": my_ip}).to_utf8_buffer(), UDP_KEY)


# --- crypto helpers ---------------------------------------------------------------

static func aes_ecb(k: PackedByteArray, data: PackedByteArray, encrypt: bool) -> PackedByteArray:
	var aes := AESContext.new()
	aes.start(AESContext.MODE_ECB_ENCRYPT if encrypt else AESContext.MODE_ECB_DECRYPT, k)
	var out := aes.update(data)
	aes.finish()
	return out


static func pkcs7(data: PackedByteArray) -> PackedByteArray:
	var n := 16 - data.size() % 16
	var out := data.duplicate()
	for i in n:
		out.append(n)
	return out


static func unpad(data: PackedByteArray) -> PackedByteArray:
	if data.is_empty():
		return data
	var n := data[-1]
	return data.slice(0, data.size() - n) if n >= 1 and n <= 16 else data


static func hmac_sha256(k: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	var h := HMACContext.new()
	h.start(HashingContext.HASH_SHA256, k)
	h.update(data)
	return h.finish()


static var _crc_table := PackedInt64Array()

static func crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for i in 256:
			var c := i
			for j in 8:
				c = (0xEDB88320 ^ (c >> 1)) if c & 1 else (c >> 1)
			_crc_table[i] = c
	var crc := 0xFFFFFFFF
	for b in data:
		crc = _crc_table[(crc ^ b) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF


static func be32(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


static func read32(buf: PackedByteArray, at: int) -> int:
	return (buf[at] << 24) | (buf[at + 1] << 16) | (buf[at + 2] << 8) | buf[at + 3]


# --- AES-GCM (Godot's AESContext has no GCM mode, so it's built from ECB) ----------

## Returns [ciphertext, tag].
static func gcm_encrypt(k: PackedByteArray, iv: PackedByteArray, plain: PackedByteArray, aad: PackedByteArray) -> Array:
	var ct := _gcm_ctr(k, iv, plain)
	return [ct, _gcm_tag(k, iv, ct, aad)]


## Decrypts without checking the tag (the bulb's HMAC/tag is not verified here).
static func gcm_decrypt(k: PackedByteArray, iv: PackedByteArray, ct: PackedByteArray, _aad: PackedByteArray) -> PackedByteArray:
	return _gcm_ctr(k, iv, ct)


static func _gcm_ctr(k: PackedByteArray, iv: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var counter := 2
	var i := 0
	while i < data.size():
		var stream := aes_ecb(k, iv + be32(counter), true)
		for j in min(16, data.size() - i):
			out.append(data[i + j] ^ stream[j])
		i += 16
		counter += 1
	return out


static func _gcm_tag(k: PackedByteArray, iv: PackedByteArray, ct: PackedByteArray, aad: PackedByteArray) -> PackedByteArray:
	var h := _to128(aes_ecb(k, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), true))
	var y := [0, 0]
	for part in [aad, ct]:
		var i := 0
		while i < part.size():
			var block: PackedByteArray = part.slice(i, i + 16)
			block.resize(16)
			var x := _to128(block)
			y = _gmul([y[0] ^ x[0], y[1] ^ x[1]], h)
			i += 16
	y = _gmul([y[0] ^ (aad.size() * 8), y[1] ^ (ct.size() * 8)], h)
	var ek := aes_ecb(k, iv + be32(1), true)
	var s := _from128(y)
	var tag := PackedByteArray()
	for j in 16:
		tag.append(s[j] ^ ek[j])
	return tag


static func _to128(b: PackedByteArray) -> Array:
	var hi := 0
	var lo := 0
	for j in 8:
		hi = (hi << 8) | b[j]
		lo = (lo << 8) | b[8 + j]
	return [hi, lo]


static func _from128(v: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for part in v:
		for j in range(7, -1, -1):
			out.append((part >> (j * 8)) & 0xFF)
	return out


## Multiplication in GF(2^128) as GCM defines it. Ints are signed 64-bit, so right
## shifts are masked to behave as unsigned.
static func _gmul(x: Array, y: Array) -> Array:
	const R := 0xE1 << 56
	var zh := 0
	var zl := 0
	var vh: int = y[0]
	var vl: int = y[1]
	for i in 128:
		var word: int = x[0] if i < 64 else x[1]
		if (word >> (63 - (i % 64))) & 1:
			zh ^= vh
			zl ^= vl
		var lsb := vl & 1
		vl = ((vl >> 1) & 0x7FFFFFFFFFFFFFFF) | ((vh & 1) << 63)
		vh = (vh >> 1) & 0x7FFFFFFFFFFFFFFF
		if lsb:
			vh ^= R
	return [zh, zl]
