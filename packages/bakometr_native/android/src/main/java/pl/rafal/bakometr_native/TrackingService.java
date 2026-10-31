package pl.rafal.bakometr_native;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

/**
 * Usługa pierwszoplanowa trzymająca proces przy życiu przez noc. Samo nagrywanie
 * i analiza dzieją się w Dart (główny isolate), usługa tylko pilnuje, żeby system
 * ich nie uśpił.
 */
public class TrackingService extends Service {
    static final int NOTIF_ID = 4201;
    static final String EXTRA_TITLE = "title";
    static final String EXTRA_TEXT = "text";

    private PowerManager.WakeLock wakeLock;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notifs.ensureChannels(this);
        String title = intent != null ? intent.getStringExtra(EXTRA_TITLE) : null;
        String text = intent != null ? intent.getStringExtra(EXTRA_TEXT) : null;
        Notification n = build(this, title != null ? title : "Rytm Snu nasłuchuje",
                text != null ? text : "");

        if (Build.VERSION.SDK_INT >= 30) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        } else {
            startForeground(NOTIF_ID, n);
        }

        if (wakeLock == null) {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bakometr:night");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire(14L * 60 * 60 * 1000); // maks. 14 h
        }
        ScreenEvents.start(this);
        return START_STICKY;
    }

    static Notification build(Context ctx, String title, String text) {
        return new Notification.Builder(ctx, Notifs.CH_TRACKING)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(Notifs.smallIcon(ctx))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setContentIntent(Notifs.openAppIntent(ctx, 1))
                .build();
    }

    static void update(Context ctx, String title, String text) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(NOTIF_ID, build(ctx, title, text));
    }

    @Override
    public void onDestroy() {
        ScreenEvents.stop(this);
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
        super.onDestroy();
    }
}
