// A MIDI client that runs outside the app, as the adb shell user, to drive
// and measure Magpie's MIDI device from another process: it opens the device
// whose name is the first argument, listens on its output port 0 and,
// depending on the mode, sends notes or a 24 PPQN clock into its input
// port 0. Every send is stamped with System.nanoTime (CLOCK_MONOTONIC, the
// same clock Magpie stamps with), so the lines below compare directly with
// the app's own stamps.
//
//   MidiProbe <name> devices
//   MidiProbe <name> listen <seconds>
//   MidiProbe <name> stall <seconds>
//       listens, but blocks in its first onSend until 3 s before the end (a
//       client that stops reading), then reads again: STALL / RESUME lines.
//   MidiProbe <name> notes <seconds> <count> <gap ms> <channel 1-16> <note>[,<note>...]
//       count note-ons (velocity 100) gap ms apart, cycling through the
//       notes, each note-off half a gap later; starts after 500 ms.
//   MidiProbe <name> clock <seconds> <bpm> <beats>
//       After 500 ms: Start, a tick every 1/24 beat for half the beats,
//       Stop, song position 8 + Continue, ticks for the other half, Stop
//       (a master Magpie must ignore: it doesn't follow a clock yet);
//       listens until seconds are up.
//
// Output, one line each (times in ns, CLOCK_MONOTONIC):
//
//   DEVICE id=.. name=.. type=.. in=.. out=..
//   OPEN id=.. sending=true|false listening=true|false
//   SENT <stamp> <hex bytes>
//   RECV <arrival> <stamp> <hex bytes>
//   DONE
//
// Build, push and run with midi_probe.sh. It runs under app_process,
// so it has no Context: it reaches the platform MidiManager through its
// (hidden) IMidiManager constructor, as Humdinger's probe does.
import android.media.midi.MidiDevice;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiInputPort;
import android.media.midi.MidiManager;
import android.media.midi.MidiOutputPort;
import android.media.midi.MidiReceiver;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import java.lang.reflect.Constructor;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

public final class MidiProbe {
    private static final StringBuilder OUT = new StringBuilder();

    @SuppressWarnings("deprecation") // MidiManager.getDevices: getDevicesForTransport is API 33+
    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.out.println("usage: MidiProbe <name> devices | listen <s> | stall <s> | notes <s> <count> <gap ms> <ch> <notes> | clock <s> <bpm> <beats>");
            System.exit(1);
        }
        String wanted = args[0];
        String mode = args[1];

        MidiManager mm = midiManager();
        MidiDeviceInfo info = null;
        for (MidiDeviceInfo d : mm.getDevices()) {
            String name = d.getProperties().getString(MidiDeviceInfo.PROPERTY_NAME);
            say("DEVICE id=" + d.getId() + " name=" + name + " type=" + d.getType()
                    + " in=" + d.getInputPortCount() + " out=" + d.getOutputPortCount());
            if (info == null && wanted.equals(name)) info = d;
        }
        if (mode.equals("devices")) {
            flush();
            System.exit(info == null ? 2 : 0);
        }
        if (info == null) {
            say("NOT_FOUND " + wanted);
            flush();
            System.exit(2);
        }

        HandlerThread thread = new HandlerThread("midi-probe");
        thread.start();
        Handler handler = new Handler(thread.getLooper());
        CountDownLatch opened = new CountDownLatch(1);
        MidiDevice[] device = new MidiDevice[1];
        mm.openDevice(info, d -> {
            device[0] = d;
            opened.countDown();
        }, handler);
        if (!opened.await(10, TimeUnit.SECONDS) || device[0] == null) {
            say("OPEN_FAILED " + wanted);
            flush();
            System.exit(4);
        }

        MidiOutputPort listen = info.getOutputPortCount() > 0 ? device[0].openOutputPort(0) : null;
        boolean sends = !mode.equals("listen") && !mode.equals("stall");
        MidiInputPort send = sends && info.getInputPortCount() > 0 ? device[0].openInputPort(0) : null;
        say("OPEN id=" + info.getId() + " sending=" + (send != null) + " listening=" + (listen != null));
        long seconds = Long.parseLong(args[2]);
        long end = System.nanoTime() + seconds * 1_000_000_000L;
        // stall: the first onSend blocks until 3 s before the end (a client
        // that stops reading), then it reads again.
        long[] stallUntil = {mode.equals("stall") ? end - 3_000_000_000L : 0};
        if (listen != null) {
            listen.connect(new MidiReceiver() {
                @Override
                public void onSend(byte[] msg, int offset, int count, long timestamp) {
                    if (stallUntil[0] > 0) {
                        say("STALL " + System.nanoTime());
                        for (long left = stallUntil[0] - System.nanoTime(); left > 0; left = stallUntil[0] - System.nanoTime()) {
                            LockSupport.parkNanos(left);
                        }
                        stallUntil[0] = 0;
                        say("RESUME " + System.nanoTime());
                    }
                    long arrival = System.nanoTime();
                    StringBuilder line = new StringBuilder("RECV ").append(arrival).append(' ').append(timestamp);
                    for (int i = offset; i < offset + count; i++) line.append(String.format(" %02x", msg[i] & 0xff));
                    say(line.toString());
                }
            });
        }
        if (sends && send == null) {
            say("PORT_BUSY " + wanted);
            flush();
            System.exit(5);
        }

        Thread.sleep(500);
        switch (mode) {
            case "listen":
            case "stall":
                break;
            case "notes":
                notes(send, Integer.parseInt(args[3]), Long.parseLong(args[4]), Integer.parseInt(args[5]), args[6]);
                break;
            case "clock":
                clock(send, Double.parseDouble(args[3]), Integer.parseInt(args[4]));
                break;
            default:
                say("UNKNOWN_MODE " + mode);
        }
        long left = end - System.nanoTime();
        if (left > 0) Thread.sleep(left / 1_000_000L);
        if (listen != null) listen.close();
        if (send != null) send.close();
        device[0].close();
        say("DONE");
        flush();
        System.exit(0);
    }

    private static void notes(MidiInputPort port, int count, long gapMs, int channel, String list) throws Exception {
        String[] parts = list.split(",");
        int ch = (channel - 1) & 0x0f;
        long gap = gapMs * 1_000_000L;
        long t = System.nanoTime();
        for (int i = 0; i < count; i++) {
            int note = Integer.parseInt(parts[i % parts.length]);
            waitUntil(t);
            send(port, (byte) (0x90 | ch), (byte) note, (byte) 100);
            waitUntil(t + gap / 2);
            send(port, (byte) (0x80 | ch), (byte) note, (byte) 0);
            t += gap;
        }
    }

    private static void clock(MidiInputPort port, double bpm, int beats) throws Exception {
        double period = 60e9 / bpm / 24;
        double t = System.nanoTime();
        send(port, (byte) 0xfa);
        for (int half = 0; half < 2; half++) {
            for (int i = 0; i < beats * 12; i++) {
                waitUntil((long) t);
                send(port, (byte) 0xf8);
                t += period;
            }
            waitUntil((long) t);
            send(port, (byte) 0xfc);
            if (half == 0) {
                send(port, (byte) 0xf2, (byte) 8, (byte) 0);
                send(port, (byte) 0xfb);
            }
        }
    }

    // Sleep to 1 ms before, then spin (Thread.onSpinWait is missing on
    // Android 10): ticks leave within a few µs of their time.
    private static void waitUntil(long t) {
        for (long left = t - System.nanoTime(); left > 1_500_000L; left = t - System.nanoTime()) {
            LockSupport.parkNanos(left - 1_000_000L);
        }
        while (System.nanoTime() < t) {
            // spin
        }
    }

    private static void send(MidiInputPort port, byte... msg) throws Exception {
        long stamp = System.nanoTime();
        port.send(msg, 0, msg.length, stamp);
        StringBuilder line = new StringBuilder("SENT ").append(stamp);
        for (byte b : msg) line.append(String.format(" %02x", b & 0xff));
        say(line.toString());
    }

    private static MidiManager midiManager() throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class)
                .invoke(null, "midi");
        Class<?> iface = Class.forName("android.media.midi.IMidiManager");
        Object service = Class.forName("android.media.midi.IMidiManager$Stub")
                .getMethod("asInterface", IBinder.class)
                .invoke(null, binder);
        Constructor<MidiManager> ctor = MidiManager.class.getDeclaredConstructor(iface);
        ctor.setAccessible(true);
        return ctor.newInstance(service);
    }

    // Lines are buffered and printed at the end, so printing never delays a
    // tick or a receive.
    private static void say(String line) {
        synchronized (OUT) {
            OUT.append(line).append('\n');
        }
    }

    private static void flush() {
        synchronized (OUT) {
            System.out.print(OUT);
            System.out.flush();
            OUT.setLength(0);
        }
    }
}
