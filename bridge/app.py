"""Small desktop app to control Tuya smart bulbs. Run: python app.py"""
import threading
import tkinter as tk
from tkinter import colorchooser, messagebox, ttk

from lights import load_bulbs


class App(tk.Tk):
    def __init__(self, bulbs):
        super().__init__()
        self.title("Domotic")
        self.resizable(False, False)
        self.bulbs = bulbs
        self.status = tk.StringVar(value=f"{len(bulbs)} light(s) loaded")

        frame = ttk.Frame(self, padding=12)
        frame.grid()
        ttk.Label(frame, text="Light").grid(row=0, column=0, sticky="w")
        self.choice = ttk.Combobox(frame, state="readonly", width=28,
                                   values=["All lights"] + [b.name for b in bulbs])
        self.choice.current(0)
        self.choice.grid(row=0, column=1, columnspan=2, pady=4)

        ttk.Button(frame, text="On", command=lambda: self.run("power", True)).grid(row=1, column=1, sticky="ew")
        ttk.Button(frame, text="Off", command=lambda: self.run("power", False)).grid(row=1, column=2, sticky="ew")

        ttk.Label(frame, text="Brightness").grid(row=2, column=0, sticky="w")
        self.bright = tk.IntVar(value=100)
        scale = ttk.Scale(frame, from_=1, to=100, variable=self.bright, orient="horizontal")
        scale.grid(row=2, column=1, columnspan=2, sticky="ew", pady=4)
        scale.bind("<ButtonRelease-1>", lambda e: self.run("brightness", self.bright.get()))

        ttk.Button(frame, text="Pick colour...", command=self.pick).grid(row=3, column=1, columnspan=2, sticky="ew")
        presets = ttk.Frame(frame)
        presets.grid(row=4, column=1, columnspan=2, pady=4)
        for i, (name, rgb) in enumerate([("Red", (255, 0, 0)), ("Green", (0, 255, 0)),
                                         ("Blue", (0, 0, 255)), ("Warm", (255, 160, 60))]):
            ttk.Button(presets, text=name, width=6, command=lambda c=rgb: self.run("colour", *c)).grid(row=0, column=i)

        ttk.Label(frame, textvariable=self.status, foreground="gray").grid(row=5, column=0, columnspan=3, sticky="w")

    def targets(self):
        i = self.choice.current()
        return self.bulbs if i == 0 else [self.bulbs[i - 1]]

    def pick(self):
        rgb, _ = colorchooser.askcolor(title="Light colour")
        if rgb:
            self.run("colour", *(int(c) for c in rgb))

    def run(self, action, *args):
        # Network calls happen off the UI thread so the window never freezes.
        def work():
            errors = []
            for bulb in self.targets():
                try:
                    getattr(bulb, action)(*args)
                except Exception as e:
                    errors.append(str(e))
            self.after(0, self.status.set, "; ".join(errors) if errors else f"{action} OK")
        self.status.set("Sending...")
        threading.Thread(target=work, daemon=True).start()


if __name__ == "__main__":
    try:
        bulbs = load_bulbs()
    except Exception as e:
        root = tk.Tk(); root.withdraw()
        messagebox.showerror("Domotic", str(e))
        raise SystemExit(1)
    App(bulbs).mainloop()
