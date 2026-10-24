package pl.rafal.bakometr_native;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.net.Uri;
import android.os.PowerManager;
import android.provider.Settings;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import android.app.Notification;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.WindowManager;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class BakometrNativePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private static final int ALARM_NOTIF_ID = 4300;

    private MethodChannel channel;
    private Context ctx;
    private Activity activity;
    private ActivityPluginBinding activityBinding;
    private HealthSync health;
    private CpapCardPicker cpapPicker;
    private String trackingTitle = "Nocny Licznik nasłuchuje";
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        ctx = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "bakometr_native");
        channel.setMethodCallHandler(this);
        Notifs.ensureChannels(ctx);
        health = new HealthSync(ctx);
        cpapPicker = new CpapCardPicker(ctx);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (health != null && health.handle(call, result, activity)) return;
        if ("pickCpapCard".equals(call.method)) {
            cpapPicker.pick(activity, call.argument("from"), call.argument("to"), result);
            return;
        }
        switch (call.method) {
            case "startTracking": {
                String title = call.argument("title");
                String text = call.argument("text");
                if (title != null) trackingTitle = title;
                Intent i = new Intent(ctx, TrackingService.class);
                i.putExtra(TrackingService.EXTRA_TITLE, trackingTitle);
                i.putExtra(TrackingService.EXTRA_TEXT, text);
                try {
                    ctx.startForegroundService(i);
                } catch (Exception e) {
                    // Bez usługi pierwszoplanowej system uśpi/zamknie aplikację w nocy — zgłaszamy to.
                    result.success("Nie udało się uruchomić usługi w tle: " + e);
                    break;
                }
                // Ekran nocy i budzika ma być widoczny bez odblokowania telefonu.
                if (activity != null && Build.VERSION.SDK_INT >= 27) activity.setShowWhenLocked(true);
                result.success(null);
                break;
            }
            case "exitReasons":
                result.success(exitReasons());
                break;
            case "batteryOptimized": {
                PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
                result.success(pm != null && !pm.isIgnoringBatteryOptimizations(ctx.getPackageName()));
                break;
            }
            case "requestIgnoreBatteryOptimizations": {
                try {
                    Intent b = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:" + ctx.getPackageName()));
                    b.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    ctx.startActivity(b);
                } catch (Exception e) {
                    Intent b = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
                    b.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    try { ctx.startActivity(b); } catch (Exception ignored) {}
                }
                result.success(null);
                break;
            }
            case "openAppSettings": {
                Intent a = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + ctx.getPackageName()));
                a.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                try { ctx.startActivity(a); } catch (Exception ignored) {}
                result.success(null);
                break;
            }
            case "deviceInfo": {
                Map<String, Object> m = new HashMap<>();
                m.put("manufacturer", Build.MANUFACTURER);
                m.put("model", Build.MODEL);
                m.put("sdk", Build.VERSION.SDK_INT);
                result.success(m);
                break;
            }
            case "updateTracking": {
                String text = call.argument("text");
                TrackingService.update(ctx, trackingTitle, text != null ? text : "");
                result.success(null);
                break;
            }
            case "stopTracking":
                ctx.stopService(new Intent(ctx, TrackingService.class));
                if (activity != null && Build.VERSION.SDK_INT >= 27) {
                    activity.setShowWhenLocked(false);
                    activity.setTurnScreenOn(false);
                }
                result.success(null);
                break;
            case "canMeasureLuxInBackground": {
                SensorManager sm = (SensorManager) ctx.getSystemService(Context.SENSOR_SERVICE);
                result.success(sm != null && sm.getDefaultSensor(Sensor.TYPE_LIGHT) != null);
                break;
            }
            case "measureLux":
                measureLux(result);
                break;
            case "vibrate": {
                Integer ms = call.argument("ms");
                Vibrator v = (Vibrator) ctx.getSystemService(Context.VIBRATOR_SERVICE);
                if (v != null && v.hasVibrator()) {
                    v.vibrate(VibrationEffect.createOneShot(ms != null ? ms : 400,
                            VibrationEffect.DEFAULT_AMPLITUDE));
                }
                result.success(null);
                break;
            }
            case "scheduleNotification": {
                Integer id = call.argument("id");
                Number at = call.argument("at");
                Boolean daily = call.argument("daily");
                ReminderReceiver.schedule(ctx, id != null ? id : 0,
                        at != null ? at.longValue() : System.currentTimeMillis(),
                        call.argument("title"), call.argument("body"),
                        daily != null && daily);
                result.success(null);
                break;
            }
            case "cancelNotification": {
                Integer id = call.argument("id");
                ReminderReceiver.cancel(ctx, id != null ? id : 0);
                result.success(null);
                break;
            }
            case "showAlarm":
                showAlarm(call.argument("title"), call.argument("body"));
                result.success(null);
                break;
            case "cancelAlarm": {
                NotificationManager nm = ctx.getSystemService(NotificationManager.class);
                if (nm != null) nm.cancel(ALARM_NOTIF_ID);
                result.success(null);
                break;
            }
            case "requestNotificationPermission":
                if (Build.VERSION.SDK_INT >= 33 && activity != null
                        && ctx.checkSelfPermission("android.permission.POST_NOTIFICATIONS")
                        != PackageManager.PERMISSION_GRANTED) {
                    activity.requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, 4400);
                }
                result.success(null);
                break;
            case "setKeepScreenOn": {
                Boolean on = call.argument("on");
                if (activity != null) {
                    if (on != null && on) {
                        activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    } else {
                        activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    }
                }
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    /** Ostatnie powody zakończenia procesu aplikacji (Android 11+). */
    private List<Map<String, Object>> exitReasons() {
        List<Map<String, Object>> out = new ArrayList<>();
        if (Build.VERSION.SDK_INT < 30) return out;
        ActivityManager am = (ActivityManager) ctx.getSystemService(Context.ACTIVITY_SERVICE);
        if (am == null) return out;
        List<ApplicationExitInfo> list = am.getHistoricalProcessExitReasons(null, 0, 16);
        for (ApplicationExitInfo e : list) {
            Map<String, Object> m = new HashMap<>();
            m.put("ts", e.getTimestamp());
            m.put("reason", e.getReason());
            m.put("description", e.getDescription() != null ? e.getDescription() : "");
            m.put("importance", e.getImportance());
            m.put("status", e.getStatus());
            m.put("pss", e.getPss());
            out.add(m);
        }
        return out;
    }

    private void measureLux(final MethodChannel.Result result) {
        final SensorManager sm = (SensorManager) ctx.getSystemService(Context.SENSOR_SERVICE);
        final Sensor light = sm != null ? sm.getDefaultSensor(Sensor.TYPE_LIGHT) : null;
        if (light == null) {
            result.success(null);
            return;
        }
        final boolean[] done = {false};
        final SensorEventListener[] holder = new SensorEventListener[1];
        holder[0] = new SensorEventListener() {
            @Override
            public void onSensorChanged(SensorEvent event) {
                if (done[0]) return;
                done[0] = true;
                sm.unregisterListener(this);
                result.success((double) event.values[0]);
            }

            @Override
            public void onAccuracyChanged(Sensor sensor, int accuracy) {}
        };
        sm.registerListener(holder[0], light, SensorManager.SENSOR_DELAY_NORMAL, main);
        // Czujnik światła zgłasza tylko zmiany — po 2 s bez zdarzenia oddajemy null.
        main.postDelayed(() -> {
            if (done[0]) return;
            done[0] = true;
            sm.unregisterListener(holder[0]);
            result.success(null);
        }, 2000);
    }

    private void showAlarm(String title, String body) {
        Notifs.ensureChannels(ctx);
        Notification n = new Notification.Builder(ctx, Notifs.CH_ALARM)
                .setContentTitle(title != null ? title : "Pobudka!")
                .setContentText(body != null ? body : "")
                .setSmallIcon(Notifs.smallIcon(ctx))
                .setCategory(Notification.CATEGORY_ALARM)
                .setOngoing(true)
                .setContentIntent(Notifs.openAppIntent(ctx, 2))
                .setFullScreenIntent(Notifs.openAppIntent(ctx, 3), true)
                .build();
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(ALARM_NOTIF_ID, n);
        if (activity != null) {
            if (Build.VERSION.SDK_INT >= 27) {
                activity.setShowWhenLocked(true);
                activity.setTurnScreenOn(true);
            }
        }
    }

    // --- ActivityAware ---
    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        attach(binding);
    }

    private void attach(ActivityPluginBinding binding) {
        activity = binding.getActivity();
        activityBinding = binding;
        if (health != null) binding.addActivityResultListener(health);
        if (cpapPicker != null) binding.addActivityResultListener(cpapPicker);
    }

    private void detach() {
        if (activityBinding != null && health != null) activityBinding.removeActivityResultListener(health);
        if (activityBinding != null && cpapPicker != null) activityBinding.removeActivityResultListener(cpapPicker);
        activityBinding = null;
        activity = null;
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        detach();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        attach(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        detach();
    }
}
