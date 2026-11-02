package pl.rafal.bakometr_native;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.widget.RemoteViews;

/** Widżet Rytmu Snu: ocena i długość ostatniej nocy, tętno i przerwy w oddechu. Dane zapisuje aplikacja. */
public class SleepWidget extends AppWidgetProvider {
    static final String PREFS = "rytm_widget";

    @Override
    public void onUpdate(Context ctx, AppWidgetManager mgr, int[] ids) {
        SharedPreferences p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Intent launch = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        PendingIntent pi = launch == null ? null
                : PendingIntent.getActivity(ctx, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        for (int id : ids) {
            RemoteViews v = new RemoteViews(ctx.getPackageName(), R.layout.rytm_widget);
            v.setTextViewText(R.id.w_score, p.getString("score", "—"));
            v.setTextViewText(R.id.w_sleep, p.getString("sleep", "Brak nocy"));
            v.setTextViewText(R.id.w_extra, p.getString("extra", ""));
            v.setTextViewText(R.id.w_date, p.getString("date", ""));
            if (pi != null) v.setOnClickPendingIntent(R.id.w_root, pi);
            mgr.updateAppWidget(id, v);
        }
    }

    /** Zapis danych i odświeżenie wszystkich widżetów. */
    static void update(Context ctx, String score, String sleep, String extra, String date) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("score", score).putString("sleep", sleep).putString("extra", extra).putString("date", date).apply();
        AppWidgetManager mgr = AppWidgetManager.getInstance(ctx);
        int[] ids = mgr.getAppWidgetIds(new ComponentName(ctx, SleepWidget.class));
        if (ids.length > 0) new SleepWidget().onUpdate(ctx, mgr, ids);
    }
}
