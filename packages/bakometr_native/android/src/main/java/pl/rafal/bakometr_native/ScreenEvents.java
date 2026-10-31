package pl.rafal.bakometr_native;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;

import java.util.ArrayList;
import java.util.List;

/**
 * Włączenia ekranu i odblokowania telefonu w nocy — pewna oznaka czuwania.
 * Rejestrowane przez usługę nocną (odbiornik dynamiczny, bez dodatkowych uprawnień).
 */
final class ScreenEvents {
    private static final List<long[]> events = new ArrayList<>(); // [czas ms, 0=off 1=on 2=odblokowanie]
    private static BroadcastReceiver receiver;

    private ScreenEvents() {}

    static synchronized void start(Context ctx) {
        if (receiver != null) return;
        receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent i) {
                String a = i.getAction();
                int t = Intent.ACTION_USER_PRESENT.equals(a) ? 2 : (Intent.ACTION_SCREEN_ON.equals(a) ? 1 : 0);
                add(System.currentTimeMillis(), t);
            }
        };
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_SCREEN_ON);
        f.addAction(Intent.ACTION_SCREEN_OFF);
        f.addAction(Intent.ACTION_USER_PRESENT);
        try {
            ctx.getApplicationContext().registerReceiver(receiver, f);
        } catch (Exception e) {
            receiver = null;
        }
    }

    static synchronized void stop(Context ctx) {
        if (receiver == null) return;
        try {
            ctx.getApplicationContext().unregisterReceiver(receiver);
        } catch (Exception ignored) {
        }
        receiver = null;
    }

    private static synchronized void add(long ts, int type) {
        events.add(new long[]{ts, type});
        if (events.size() > 3000) events.subList(0, 1000).clear();
    }

    static synchronized List<List<Long>> since(long fromMs) {
        List<List<Long>> out = new ArrayList<>();
        for (long[] e : events) {
            if (e[0] >= fromMs) {
                List<Long> r = new ArrayList<>();
                r.add(e[0]);
                r.add(e[1]);
                out.add(r);
            }
        }
        return out;
    }
}
