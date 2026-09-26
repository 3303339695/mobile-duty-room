package com.zhibanshi.mobile.dutyroom;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.IBinder;
import android.os.PowerManager;
import android.provider.DocumentsContract;

public class DutyRoomGuardService extends Service {
    private static final String CHANNEL_ID = "dutyroom_guard";
    private static final int NOTIFICATION_ID = 7315;
    private static final long HEARTBEAT_MS = 30000L;
    private static final long WATCHDOG_POKE_MS = 60000L;
    private static final long RESTART_DELAY_MS = 15000L;
    private static final String TERMUX_PACKAGE = "com.termux";
    private static final String TERMUX_SERVICE = "com.termux.app.RunCommandService";
    private static final String TERMUX_ACTION = "com.termux.RUN_COMMAND";
    private static final String EXTRA_PATH = "com.termux.RUN_COMMAND_PATH";
    private static final String EXTRA_ARGUMENTS = "com.termux.RUN_COMMAND_ARGUMENTS";
    private static final String EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR";
    private static final String EXTRA_RUNNER = "com.termux.RUN_COMMAND_RUNNER";
    private static final String EXTRA_BACKGROUND = "com.termux.RUN_COMMAND_BACKGROUND";
    private static final String EXTRA_COMMAND_LABEL = "com.termux.RUN_COMMAND_COMMAND_LABEL";
    private static final String PREFS_NAME = "zhibanshi";
    private static final String PREF_PUBLIC_TREE = "public_tree";

    private Handler handler;
    private PowerManager.WakeLock wakeLock;
    private final Runnable heartbeat = new Runnable() {
        @Override
        public void run() {
            updateNotification();
            pokeWatchdog();
        }
    };

    public static void start(Context context) {
        Intent intent = new Intent(context, DutyRoomGuardService.class);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (RuntimeException ignored) {
            // Android may defer background starts; the receiver/activity will retry.
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        handler = new Handler(getMainLooper());
        PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
        if (power != null) {
            wakeLock = power.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    getPackageName() + ":dutyroom-guard");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire();
        }
        createChannel();
        startForeground(NOTIFICATION_ID, buildNotification());
        pokeWatchdog();
        scheduleHeartbeat();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        scheduleRestart();
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        if (handler != null) {
            handler.removeCallbacksAndMessages(null);
        }
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
        scheduleRestart();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void scheduleHeartbeat() {
        if (handler != null) {
            handler.removeCallbacks(heartbeat);
            handler.postDelayed(heartbeat, HEARTBEAT_MS);
        }
    }

    private void scheduleRestart() {
        AlarmManager alarms = (AlarmManager) getSystemService(ALARM_SERVICE);
        if (alarms == null) {
            return;
        }
        PendingIntent pending = restartPendingIntent();
        long triggerAt = System.currentTimeMillis() + RESTART_DELAY_MS;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending);
        } else {
            alarms.set(AlarmManager.RTC_WAKEUP, triggerAt, pending);
        }
    }

    private PendingIntent restartPendingIntent() {
        Intent intent = new Intent(this, DutyRoomGuardService.class);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getService(this, 7315, intent, flags);
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "值班室后台守护",
                    NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("保持值班室后台守护服务运行");
            channel.setShowBadge(false);
            manager.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification() {
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent content = null;
        if (launch != null) {
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            content = PendingIntent.getActivity(this, 7316, launch, flags);
        }
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        builder.setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("手机端值班室正在后台守护")
                .setContentText("保持 ZeroTermux 任务的后台运行条件")
                .setOngoing(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setPriority(Notification.PRIORITY_LOW);
        if (content != null) {
            builder.setContentIntent(content);
        }
        return builder.build();
    }

    private void updateNotification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) {
            manager.notify(NOTIFICATION_ID, buildNotification());
        }
        scheduleHeartbeat();
    }

    private void pokeWatchdog() {
        String publicRoot = publicRootPath();
        if (publicRoot == null || !new java.io.File(publicRoot, "bin/zbs.sh").isFile()) {
            return;
        }
        Intent intent = new Intent();
        intent.setClassName(TERMUX_PACKAGE, TERMUX_SERVICE);
        intent.setAction(TERMUX_ACTION);
        intent.putExtra(EXTRA_PATH, "/data/data/com.termux/files/usr/bin/bash");
        intent.putExtra(EXTRA_ARGUMENTS, new String[]{
                new java.io.File(publicRoot, "bin/zbs.sh").getAbsolutePath(),
                "start-watchdog"
        });
        intent.putExtra(EXTRA_WORKDIR, publicRoot);
        intent.putExtra(EXTRA_RUNNER, "app-shell");
        intent.putExtra(EXTRA_BACKGROUND, true);
        intent.putExtra(EXTRA_COMMAND_LABEL, "值班室服务守护");
        try {
            startService(intent);
        } catch (RuntimeException ignored) {
            // Permission or Termux state will be retried on the next heartbeat.
        }
    }

    private String publicRootPath() {
        SharedPreferences preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        String stored = preferences.getString(PREF_PUBLIC_TREE, null);
        if (stored == null || stored.trim().isEmpty()) {
            return new java.io.File(
                    Environment.getExternalStorageDirectory(), "手机端值班室").getAbsolutePath();
        }
        try {
            Uri tree = Uri.parse(stored);
            String documentId = DocumentsContract.getTreeDocumentId(tree);
            if (documentId.startsWith("primary:")) {
                String relative = documentId.substring("primary:".length());
                while (relative.startsWith("/")) {
                    relative = relative.substring(1);
                }
                return relative.isEmpty()
                        ? Environment.getExternalStorageDirectory().getAbsolutePath()
                        : new java.io.File(
                                Environment.getExternalStorageDirectory(), relative).getAbsolutePath();
            }
            if (documentId.startsWith("raw:")) {
                return new java.io.File(documentId.substring("raw:".length())).getAbsolutePath();
            }
        } catch (Exception ignored) {
        }
        return null;
    }
}
