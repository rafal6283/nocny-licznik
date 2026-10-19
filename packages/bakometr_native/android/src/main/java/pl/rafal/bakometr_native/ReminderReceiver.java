package pl.rafal.bakometr_native;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Zaplanowane powiadomienia (przypomnienie o śnie), opcjonalnie codzienne. */
public class ReminderReceiver extends BroadcastReceiver {
    static final String EXTRA_ID = "id";
    static final String EXTRA_TITLE = "title";
    static final String EXTRA_BODY = "body";
    static final String EXTRA_DAILY = "daily";
    static final String EXTRA_AT = "at";

    @Override
    public void onReceive(Context ctx, Intent intent) {
        Notifs.ensureChannels(ctx);
        int id = intent.getIntExtra(EXTRA_ID, 0);
        Notification n = new Notification.Builder(ctx, Notifs.CH_REMINDER)
                .setContentTitle(intent.getStringExtra(EXTRA_TITLE))
                .setContentText(intent.getStringExtra(EXTRA_BODY))
                .setSmallIcon(Notifs.smallIcon(ctx))
                .setAutoCancel(true)
                .setContentIntent(Notifs.openAppIntent(ctx, 100 + id))
                .build();
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(5000 + id, n);

        if (intent.getBooleanExtra(EXTRA_DAILY, false)) {
            long next = intent.getLongExtra(EXTRA_AT, System.currentTimeMillis()) + 24L * 3600 * 1000;
            while (next < System.currentTimeMillis()) next += 24L * 3600 * 1000;
            schedule(ctx, id, next, intent.getStringExtra(EXTRA_TITLE),
                    intent.getStringExtra(EXTRA_BODY), true);
        }
    }

    static void schedule(Context ctx, int id, long at, String title, String body, boolean daily) {
        Intent i = new Intent(ctx, ReminderReceiver.class);
        i.putExtra(EXTRA_ID, id);
        i.putExtra(EXTRA_TITLE, title);
        i.putExtra(EXTRA_BODY, body);
        i.putExtra(EXTRA_DAILY, daily);
        i.putExtra(EXTRA_AT, at);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, id, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        AlarmManager am = ctx.getSystemService(AlarmManager.class);
        if (am == null) return;
        // Niedokładne, ale nie wymaga uprawnienia do dokładnych alarmów.
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi);
    }

    static void cancel(Context ctx, int id) {
        Intent i = new Intent(ctx, ReminderReceiver.class);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, id, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        AlarmManager am = ctx.getSystemService(AlarmManager.class);
        if (am != null) am.cancel(pi);
        pi.cancel();
    }
}
