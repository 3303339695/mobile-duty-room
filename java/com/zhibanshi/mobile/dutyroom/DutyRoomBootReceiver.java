package com.zhibanshi.mobile.dutyroom;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class DutyRoomBootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? "" : intent.getAction();
        if (Intent.ACTION_BOOT_COMPLETED.equals(action)
                || Intent.ACTION_LOCKED_BOOT_COMPLETED.equals(action)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) {
            DutyRoomGuardService.start(context);
        }
    }
}
