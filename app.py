"""Church AI Translation — desktop control panel (PySide6).

Run with:  venv/bin/python app.py
Normally started by double-clicking "Church AI Translation.app".
"""
import math
import os
import subprocess
import sys
import threading
import time

from PySide6.QtCore import QObject, Qt, QTimer, Signal, QUrl
from PySide6.QtGui import QColor, QDesktopServices, QFont, QPainter, QPen
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QCheckBox, QComboBox, QDialog,
    QDialogButtonBox, QDoubleSpinBox, QFormLayout, QFrame, QHBoxLayout,
    QHeaderView, QLabel, QMainWindow, QMessageBox, QProgressBar, QPushButton,
    QSizePolicy, QSpinBox, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

import engine as eng
from app_config import TRANSCRIPTS_DIR, load_settings, save_settings

GREEN = QColor("#639922")
AMBER = QColor("#EF9F27")
RED = QColor("#E24B4A")
METER_MIN_DB = -60.0


def rms_to_fraction(rms):
    """Map loudness to 0..1 on a decibel scale (like a mixing desk)."""
    if rms <= 0:
        return 0.0
    db = 20 * math.log10(rms)
    return max(0.0, min(1.0, (db - METER_MIN_DB) / -METER_MIN_DB))


# ------------------------------------------------------------------
# Widgets
# ------------------------------------------------------------------
class LevelMeter(QWidget):
    """Vertical green/amber/red level meter with peak hold and an optional cutoff line."""

    def __init__(self, show_threshold=False):
        super().__init__()
        self.setFixedWidth(30)
        self.setMinimumHeight(200)
        self.level = 0.0
        self.peak = 0.0
        self.peak_time = 0.0
        self.threshold = None if not show_threshold else 0.0

    def set_level(self, fraction):
        # Fast attack, slower release so the bar is easy to read
        self.level = fraction if fraction > self.level else self.level * 0.80 + fraction * 0.20
        now = time.time()
        if fraction >= self.peak or now - self.peak_time > 1.5:
            self.peak, self.peak_time = fraction, now
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        r = self.rect().adjusted(0, 0, -1, -1)
        p.setPen(QPen(self.palette().mid().color()))
        p.setBrush(self.palette().base())
        p.drawRoundedRect(r, 4, 4)
        h = r.height() - 4
        segments = 30
        seg_h = h / segments
        lit = int(self.level * segments + 0.5)
        for i in range(segments):
            frac = (i + 1) / segments
            color = GREEN if frac <= 0.70 else AMBER if frac <= 0.88 else RED
            if i >= lit:
                color = QColor(color)
                color.setAlpha(35)
            y = r.bottom() - 2 - (i + 1) * seg_h
            p.fillRect(int(r.left() + 3), int(y + 1), r.width() - 6, max(1, int(seg_h - 1)), color)
        if self.peak > 0.02:
            y = r.bottom() - 2 - self.peak * h
            p.fillRect(int(r.left() + 3), int(y), r.width() - 6, 2, self.palette().text().color())
        if self.threshold is not None:
            y = r.bottom() - 2 - self.threshold * h
            pen = QPen(self.palette().text().color(), 2, Qt.DashLine)
            p.setPen(pen)
            p.drawLine(r.left() - 1, int(y), r.right() + 1, int(y))
        p.end()


class Dot(QLabel):
    def __init__(self, size=12):
        super().__init__()
        self.setFixedSize(size, size)
        self.set_color("#B4B2A9")

    def set_color(self, hex_color):
        r = self.width() // 2
        self.setStyleSheet(f"background:{hex_color}; border-radius:{r}px;")


class CaptionWindow(QWidget):
    """Large Spanish captions for a projector or TV. Esc closes, double-click toggles full screen."""

    def __init__(self, font_size):
        super().__init__()
        self.setWindowTitle("Spanish captions")
        self.setStyleSheet("background:#111111;")
        self.prev = QLabel("")
        self.curr = QLabel("Esperando la traducción…")
        for lbl in (self.prev, self.curr):
            lbl.setWordWrap(True)
            lbl.setAlignment(Qt.AlignLeft | Qt.AlignBottom)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(60, 40, 60, 60)
        lay.addStretch(1)
        lay.addWidget(self.prev)
        lay.addWidget(self.curr)
        self.set_font_size(font_size)
        self.resize(1100, 450)

    def set_font_size(self, size):
        self.prev.setStyleSheet(f"color:#888780; font-size:{int(size * 0.65)}pt;")
        self.curr.setStyleSheet(f"color:#F4F3EE; font-size:{size}pt; font-weight:600;")

    def add_line(self, text):
        self.prev.setText(self.curr.text() if self.curr.text() != "Esperando la traducción…" else "")
        self.curr.setText(text)

    def show_on_best_screen(self):
        screens = QApplication.screens()
        if len(screens) > 1:
            # Put captions on the second display (projector/TV) in full screen
            self.setScreen(screens[1])
            self.move(screens[1].geometry().topLeft())
            self.showFullScreen()
        else:
            self.showNormal()
        self.raise_()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self.hide()
        else:
            super().keyPressEvent(e)

    def mouseDoubleClickEvent(self, _):
        self.showNormal() if self.isFullScreen() else self.showFullScreen()


class SettingsDialog(QDialog):
    def __init__(self, settings, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Settings")
        self.s = settings
        form = QFormLayout(self)

        self.speed = QComboBox()
        self.speed.addItem("Normal", "normal")
        self.speed.addItem("Fast", "fast")
        self.speed.setCurrentIndex(1 if settings.speech_speed == "fast" else 0)
        form.addRow("Spanish speech speed", self.speed)

        self.chunk = QDoubleSpinBox()
        self.chunk.setRange(2.0, 6.0)
        self.chunk.setSingleStep(0.5)
        self.chunk.setSuffix(" s")
        self.chunk.setValue(settings.block_size_seconds)
        self.chunk.setToolTip("How much speech is collected before each translation.\n"
                              "Shorter is quicker but can cut sentences apart.")
        form.addRow("Listen in chunks of", self.chunk)

        self.threshold = QDoubleSpinBox()
        self.threshold.setDecimals(4)
        self.threshold.setRange(0.0005, 0.05)
        self.threshold.setSingleStep(0.0005)
        self.threshold.setValue(settings.silence_threshold)
        self.threshold.setToolTip("Sound quieter than this is ignored as silence.\n"
                                  "Shown as the dashed line on the microphone meter.")
        form.addRow("Silence cutoff", self.threshold)

        self.font_size = QSpinBox()
        self.font_size.setRange(24, 120)
        self.font_size.setSuffix(" pt")
        self.font_size.setValue(settings.caption_font_size)
        form.addRow("Caption text size", self.font_size)

        self.auto = QCheckBox("Start listening as soon as the app is ready")
        self.auto.setChecked(settings.auto_start)
        form.addRow("", self.auto)

        note = QLabel("Speed, chunk and cutoff changes apply the next time you press Start.")
        note.setWordWrap(True)
        note.setStyleSheet("color: gray; font-size: 11px;")
        form.addRow(note)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        form.addRow(buttons)

    def apply(self):
        self.s.speech_speed = self.speed.currentData()
        self.s.block_size_seconds = self.chunk.value()
        self.s.silence_threshold = self.threshold.value()
        self.s.caption_font_size = self.font_size.value()
        self.s.auto_start = self.auto.isChecked()


class Bridge(QObject):
    """Carries engine callbacks (from worker threads) safely onto the GUI thread."""
    status = Signal(str, str)
    transcript = Signal(str, str, str, float)


# ------------------------------------------------------------------
# Main window
# ------------------------------------------------------------------
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Church AI Translation")
        self.resize(1100, 640)
        self.settings = load_settings()
        self.bridge = Bridge()
        self.bridge.status.connect(self.on_status)
        self.bridge.transcript.connect(self.on_transcript)
        self.engine = eng.TranslatorEngine(
            on_status=self.bridge.status.emit,
            on_transcript=self.bridge.transcript.emit,
        )
        self.state = "loading"
        self.started_at = None
        self.caffeinate = None
        self.transcript_file = None
        self.captions = CaptionWindow(self.settings.caption_font_size)

        self._build_ui()
        self.populate_devices()

        self.meter_timer = QTimer(self, interval=50, timeout=self.tick_meters)
        self.meter_timer.start()
        self.clock_timer = QTimer(self, interval=1000, timeout=self.tick_clock)
        self.clock_timer.start()

        self.on_status("loading", "Starting up…")
        threading.Thread(target=self.engine.load_models, daemon=True).start()

    # ---------------- layout ----------------
    def _build_ui(self):
        root = QWidget()
        outer = QVBoxLayout(root)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        # Top bar
        top = QHBoxLayout()
        top.setContentsMargins(16, 12, 16, 12)
        self.start_btn = QPushButton("Start")
        self.start_btn.setMinimumSize(130, 44)
        self.start_btn.clicked.connect(self.toggle_listening)
        top.addWidget(self.start_btn)

        self.status_box = QFrame()
        self.status_box.setObjectName("statusBox")
        sb = QHBoxLayout(self.status_box)
        sb.setContentsMargins(12, 6, 12, 6)
        self.status_dot = Dot()
        self.status_label = QLabel()
        self.status_label.setStyleSheet("font-size: 14px;")
        sb.addWidget(self.status_dot)
        sb.addWidget(self.status_label)
        top.addWidget(self.status_box)

        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setMaximumWidth(140)
        self.progress.setTextVisible(False)
        top.addWidget(self.progress)

        top.addStretch(1)
        lang = QLabel("English → Spanish")
        lang.setStyleSheet("color: gray;")
        top.addWidget(lang)
        top.addSpacing(16)
        self.clock_label = QLabel("00:00:00")
        self.clock_label.setStyleSheet("font-size: 14px;")
        self.clock_label.setToolTip("Time since Start was pressed")
        top.addWidget(self.clock_label)
        settings_btn = QPushButton("Settings")
        settings_btn.clicked.connect(self.open_settings)
        top.addWidget(settings_btn)
        outer.addLayout(top)
        outer.addWidget(self._hline())

        # Middle: left panel + transcript
        mid = QHBoxLayout()
        mid.setContentsMargins(0, 0, 0, 0)
        mid.setSpacing(0)

        left = QWidget()
        left.setFixedWidth(250)
        lv = QVBoxLayout(left)
        lv.setContentsMargins(16, 14, 16, 14)
        lv.addWidget(self._caption("Microphone (English in)"))
        self.in_combo = QComboBox()
        self.in_combo.currentIndexChanged.connect(self.devices_changed)
        lv.addWidget(self.in_combo)
        lv.addSpacing(6)
        lv.addWidget(self._caption("Speakers / headsets (Spanish out)"))
        self.out_combo = QComboBox()
        self.out_combo.currentIndexChanged.connect(self.devices_changed)
        lv.addWidget(self.out_combo)
        refresh = QPushButton("Refresh device list")
        refresh.clicked.connect(lambda: self.populate_devices(rescan=True))
        lv.addWidget(refresh)
        lv.addSpacing(10)

        meters = QHBoxLayout()
        in_col = QVBoxLayout()
        self.clip_dot = Dot(10)
        self.clip_dot.setToolTip("Turns red if the microphone is too loud (clipping)")
        in_col.addWidget(self.clip_dot, alignment=Qt.AlignHCenter)
        self.in_meter = LevelMeter(show_threshold=True)
        in_col.addWidget(self.in_meter, 1, alignment=Qt.AlignHCenter)
        in_col.addWidget(QLabel("In"), alignment=Qt.AlignHCenter)
        meters.addLayout(in_col)
        out_col = QVBoxLayout()
        out_col.addSpacing(14)
        self.out_meter = LevelMeter()
        out_col.addWidget(self.out_meter, 1, alignment=Qt.AlignHCenter)
        out_col.addWidget(QLabel("Out"), alignment=Qt.AlignHCenter)
        meters.addLayout(out_col)
        info = QVBoxLayout()
        info.addStretch(1)
        legend = QLabel("- - -  silence cutoff\nSound below the line\nis not translated.")
        legend.setStyleSheet("color: gray; font-size: 11px;")
        info.addWidget(legend)
        info.addSpacing(10)
        info.addWidget(self._caption("Speech heard"))
        self.heard_label = QLabel("—")
        self.heard_label.setStyleSheet("font-size: 16px;")
        info.addWidget(self.heard_label)
        info.addSpacing(18)
        meters.addLayout(info, 1)
        lv.addLayout(meters, 1)

        self.test_btn = QPushButton("Test speakers")
        self.test_btn.clicked.connect(self.test_speakers)
        lv.addWidget(self.test_btn)
        mid.addWidget(left)
        mid.addWidget(self._vline())

        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["Time", "English", "Spanish"])
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setWordWrap(True)
        self.table.setShowGrid(False)
        self.table.setAlternatingRowColors(True)
        hdr = self.table.horizontalHeader()
        hdr.setSectionResizeMode(0, QHeaderView.ResizeToContents)
        hdr.setSectionResizeMode(1, QHeaderView.Stretch)
        hdr.setSectionResizeMode(2, QHeaderView.Stretch)
        self.table.setStyleSheet("QTableWidget { font-size: 14px; border: none; }")
        mid.addWidget(self.table, 1)
        outer.addLayout(mid, 1)
        outer.addWidget(self._hline())

        # Bottom bar
        bottom = QHBoxLayout()
        bottom.setContentsMargins(16, 8, 16, 8)
        self.delay_label = QLabel("Delay: —")
        self.delay_label.setToolTip("Time from the end of each English phrase to the Spanish being spoken")
        self.queue_label = QLabel("Waiting: 0")
        self.queue_label.setToolTip("Phrases waiting to be translated or spoken")
        self.speed_label = QLabel()
        for w in (self.delay_label, self.queue_label, self.speed_label):
            w.setStyleSheet("color: gray;")
            bottom.addWidget(w)
            bottom.addSpacing(14)
        bottom.addStretch(1)
        cap_btn = QPushButton("Show captions")
        cap_btn.clicked.connect(self.captions.show_on_best_screen)
        bottom.addWidget(cap_btn)
        clear_btn = QPushButton("Clear")
        clear_btn.clicked.connect(lambda: self.table.setRowCount(0))
        bottom.addWidget(clear_btn)
        tx_btn = QPushButton("Open transcripts")
        tx_btn.clicked.connect(self.open_transcripts)
        bottom.addWidget(tx_btn)
        outer.addLayout(bottom)

        self.setCentralWidget(root)
        self._update_speed_label()

    def _hline(self):
        f = QFrame()
        f.setFrameShape(QFrame.HLine)
        f.setStyleSheet("color: palette(mid);")
        return f

    def _vline(self):
        f = QFrame()
        f.setFrameShape(QFrame.VLine)
        f.setStyleSheet("color: palette(mid);")
        return f

    def _caption(self, text):
        lbl = QLabel(text)
        lbl.setStyleSheet("color: gray; font-size: 12px;")
        return lbl

    def _update_speed_label(self):
        self.speed_label.setText(f"Speech speed: {self.settings.speech_speed}")
        self.in_meter.threshold = rms_to_fraction(self.settings.silence_threshold)

    # ---------------- devices ----------------
    def populate_devices(self, rescan=False):
        if rescan:
            if self.engine.listening:
                QMessageBox.information(self, "Devices", "Stop translating before refreshing the device list.")
                return
            eng.refresh_devices()
        for combo, kind, saved in (
            (self.in_combo, "input", self.settings.input_device_name),
            (self.out_combo, "output", self.settings.output_device_name),
        ):
            combo.blockSignals(True)
            combo.clear()
            names = [n for _, n in eng.list_devices(kind)]
            for n in names:
                combo.addItem(n, n)
            if saved and saved not in names:
                combo.insertItem(0, f"{saved}  (not connected)", saved)
            if saved:
                combo.setCurrentIndex(combo.findData(saved))
            elif names:
                # First run: pick a USB device if there is one, else the first device
                usb = [i for i, n in enumerate(names) if "usb" in n.lower()]
                combo.setCurrentIndex(usb[0] if usb else 0)
            combo.blockSignals(False)
        self.devices_changed()

    def devices_changed(self):
        self.settings.input_device_name = self.in_combo.currentData() or ""
        self.settings.output_device_name = self.out_combo.currentData() or ""
        save_settings(self.settings)

    # ---------------- actions ----------------
    def toggle_listening(self):
        if self.engine.listening:
            self.stop_listening()
        else:
            self.start_listening()

    def start_listening(self):
        s = self.settings
        try:
            self.engine.start(s.input_device_name, s.output_device_name,
                              s.block_size_seconds, s.silence_threshold, s.speech_speed)
        except eng.EngineError as e:
            self.on_status("error", str(e))
            return
        self.started_at = time.time()
        self.in_combo.setEnabled(False)
        self.out_combo.setEnabled(False)
        self._open_transcript_file()
        self._keep_awake(True)
        notify("Live translation is listening.")

    def stop_listening(self):
        self.engine.stop()
        self.started_at = None
        self.in_combo.setEnabled(True)
        self.out_combo.setEnabled(True)
        self._keep_awake(False)
        if self.transcript_file:
            self.transcript_file.close()
            self.transcript_file = None

    def test_speakers(self):
        try:
            self.engine.test_speakers(self.settings.output_device_name)
        except eng.EngineError as e:
            QMessageBox.warning(self, "Test speakers", str(e))

    def open_settings(self):
        dlg = SettingsDialog(self.settings, self)
        if dlg.exec():
            dlg.apply()
            save_settings(self.settings)
            self.captions.set_font_size(self.settings.caption_font_size)
            self._update_speed_label()

    def open_transcripts(self):
        os.makedirs(TRANSCRIPTS_DIR, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(TRANSCRIPTS_DIR))

    def _open_transcript_file(self):
        os.makedirs(TRANSCRIPTS_DIR, exist_ok=True)
        path = os.path.join(TRANSCRIPTS_DIR, time.strftime("%Y-%m-%d %H-%M") + ".txt")
        self.transcript_file = open(path, "a", encoding="utf-8")
        self.transcript_file.write(f"Church AI Translation — {time.strftime('%A %d %B %Y, %H:%M')}\n\n")
        self.transcript_file.flush()

    def _keep_awake(self, on):
        """Stop the Mac sleeping (display and system) while translating."""
        if on and self.caffeinate is None:
            try:
                self.caffeinate = subprocess.Popen(
                    ["caffeinate", "-dims", "-w", str(os.getpid())])
            except Exception:
                self.caffeinate = None
        elif not on and self.caffeinate is not None:
            self.caffeinate.terminate()
            self.caffeinate = None

    # ---------------- engine callbacks ----------------
    def on_status(self, state, message):
        self.state = state
        self.status_label.setText(message)
        self.progress.setVisible(state == "loading")
        colors = {
            "loading": ("#B4B2A9", "Start"),
            "ready": ("#378ADD", "Start"),
            "listening": ("#639922", "Stop"),
            "error": ("#E24B4A", "Start"),
        }
        dot, label = colors.get(state, ("#B4B2A9", "Start"))
        self.status_dot.set_color(dot)
        self.start_btn.setText(label)
        self.start_btn.setEnabled(self.engine.models_loaded)
        self.test_btn.setEnabled(self.engine.models_loaded)
        if label == "Stop":
            self.start_btn.setStyleSheet(
                "QPushButton { background:#E24B4A; color:white; font-size:16px; font-weight:600;"
                " border-radius:8px; }")
        else:
            self.start_btn.setStyleSheet(
                "QPushButton { background:#3B6D11; color:white; font-size:16px; font-weight:600;"
                " border-radius:8px; } QPushButton:disabled { background:#B4B2A9; }")
        if state == "error":
            self.status_box.setStyleSheet("#statusBox { background: rgba(226,75,74,0.15); border-radius: 8px; }")
        else:
            self.status_box.setStyleSheet("#statusBox { background: rgba(128,128,128,0.12); border-radius: 8px; }")
        if state == "ready" and self.settings.auto_start and self.started_at is None \
                and not getattr(self, "_auto_started", False):
            self._auto_started = True
            QTimer.singleShot(500, self.start_listening)

    def on_transcript(self, ts, en, es, latency):
        row = self.table.rowCount()
        self.table.insertRow(row)
        for col, text in enumerate((ts, en, es)):
            item = QTableWidgetItem(text)
            item.setTextAlignment(Qt.AlignLeft | Qt.AlignTop)
            if col == 0:
                item.setForeground(QColor("gray"))
            self.table.setItem(row, col, item)
        self.table.resizeRowToContents(row)
        self.table.scrollToBottom()
        self.captions.add_line(es)
        color = "#3B6D11" if latency < 3 else "#BA7517" if latency < 6 else "#A32D2D"
        self.delay_label.setText(f"Delay: <span style='color:{color}'>{latency:.1f}s</span>")
        if self.transcript_file:
            self.transcript_file.write(f"[{ts}] EN: {en}\n[{ts}] ES: {es}\n\n")
            self.transcript_file.flush()

    # ---------------- timers ----------------
    def tick_meters(self):
        e = self.engine
        self.in_meter.set_level(rms_to_fraction(e.input_rms) if e.listening else 0.0)
        self.out_meter.set_level(rms_to_fraction(e.output_rms()))
        clipping = time.time() - e.last_clip_time < 1.0
        self.clip_dot.set_color("#E24B4A" if clipping else "#B4B2A9")
        self.queue_label.setText(f"Waiting: {e.queue_depth()}")

    def tick_clock(self):
        e = self.engine
        if self.started_at:
            el = int(time.time() - self.started_at)
            self.clock_label.setText(f"{el // 3600:02d}:{el % 3600 // 60:02d}:{el % 60:02d}")
        if e.listening:
            if e.last_speech_time == 0:
                self.heard_label.setText("Not yet")
                ago = time.time() - (self.started_at or time.time())
            else:
                ago = time.time() - e.last_speech_time
                self.heard_label.setText("Now" if ago < 1.5 else f"{int(ago)}s ago")
            # Warn the volunteer if the microphone has gone quiet
            if ago > 20:
                self.status_dot.set_color("#EF9F27")
                self.status_label.setText("Listening, but no sound from the microphone. Check it's on and unmuted.")
            elif self.state == "listening":
                self.status_dot.set_color("#639922")
                self.status_label.setText(f"Listening on {self.settings.input_device_name}")
        else:
            self.heard_label.setText("—")

    def closeEvent(self, event):
        if self.engine.listening:
            ans = QMessageBox.question(
                self, "Quit", "Translation is still running. Stop and quit?",
                QMessageBox.Yes | QMessageBox.No)
            if ans != QMessageBox.Yes:
                event.ignore()
                return
            self.stop_listening()
        self.captions.close()
        event.accept()


def notify(message):
    try:
        subprocess.Popen([
            "osascript", "-e",
            f'display notification "{message}" with title "Church AI Translation" sound name "Glass"',
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("Church AI Translation")
    f = app.font()
    f.setPointSize(max(f.pointSize(), 13))
    app.setFont(f)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
