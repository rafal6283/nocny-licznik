package pl.rafal.bakometr_native;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.RingtoneManager;

/** Wspólne kanały powiadomień i intencje otwierające aplikację. */
final class Notifs {
    static final String CH_TRACKING = "bakometr_tracking";
    static final String CH_REMINDER = "bakometr_reminder";
    static final String CH_ALARM = "bakometr_alarm";

    private Notifs() {}

    static void ensureChannels(Context ctx) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm == null) return;

        NotificationChannel tracking = new NotificationChannel(
                CH_TRACKING, "Śledzenie snu", NotificationManager.IMPORTANCE_LOW);
        tracking.setDescription("Widoczne, gdy Rytm Snu nasłuchuje w nocy");
        tracking.setShowBadge(false);
        nm.createNotificationChannel(tracking);

        NotificationChannel reminder = new NotificationChannel(
                CH_REMINDER, "Przypomnienia", NotificationManager.IMPORTANCE_DEFAULT);
        reminder.setDescription("Przypomnienie o pójściu spać");
        nm.createNotificationChannel(reminder);

        NotificationChannel alarm = new NotificationChannel(
                CH_ALARM, "Budzik", NotificationManager.IMPORTANCE_HIGH);
        alarm.setDescription("Budzik Rytmu Snu");
        alarm.setBypassDnd(true);
        alarm.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build());
        nm.createNotificationChannel(alarm);
    }

    static PendingIntent openAppIntent(Context ctx, int requestCode) {
        Intent launch = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        if (launch == null) launch = new Intent();
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        return PendingIntent.getActivity(ctx, requestCode, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static int smallIcon(Context ctx) {
        int icon = ctx.getApplicationInfo().icon;
        return icon != 0 ? icon : android.R.drawable.ic_lock_idle_alarm;
    }
}
