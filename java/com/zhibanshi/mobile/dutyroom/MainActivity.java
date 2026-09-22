package com.zhibanshi.mobile.dutyroom;

import android.Manifest;
import android.app.Activity;
import android.app.AppOpsManager;
import android.app.AlertDialog;
import android.app.Dialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.PermissionInfo;
import android.content.res.AssetManager;
import android.database.Cursor;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.PowerManager;
import android.provider.DocumentsContract;
import android.provider.Settings;
import android.util.Base64;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class MainActivity extends Activity {
    private static final String TERMUX_PACKAGE = "com.termux";
    private static final String EDGE_PACKAGE = "com.microsoft.emmx";
    private static final String TERMUX_SERVICE = "com.termux.app.RunCommandService";
    private static final String TERMUX_ACTION = "com.termux.RUN_COMMAND";
    private static final String EXTRA_PATH = "com.termux.RUN_COMMAND_PATH";
    private static final String EXTRA_ARGUMENTS = "com.termux.RUN_COMMAND_ARGUMENTS";
    private static final String EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR";
    private static final String EXTRA_RUNNER = "com.termux.RUN_COMMAND_RUNNER";
    private static final String EXTRA_SESSION_ACTION = "com.termux.RUN_COMMAND_SESSION_ACTION";
    private static final String EXTRA_SHELL_NAME = "com.termux.RUN_COMMAND_SHELL_NAME";
    private static final String EXTRA_SHELL_CREATE_MODE = "com.termux.RUN_COMMAND_SHELL_CREATE_MODE";
    private static final String EXTRA_COMMAND_LABEL = "com.termux.RUN_COMMAND_COMMAND_LABEL";
    private static final String TERMUX_PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final String PUBLIC_ROOT_NAME = "手机端值班室";
    private static final String PREFS_NAME = "zhibanshi";
    private static final String PREF_PUBLIC_TREE = "public_tree";
    private static final String PREF_BACKUP_TREE = "backup_tree";
    private static final String PREF_TERMUX_PERMISSION_REQUESTED =
            "termux_permission_requested";
    private static final int REQUEST_PUBLIC_STORAGE = 4101;
    private static final int REQUEST_BACKUP_STORAGE = 4102;
    private static final int REQUEST_TERMUX_PERMISSION = 4103;

    private WebView webView;
    private File publicRoot;
    private File requestDir;
    private SharedPreferences preferences;
    private Uri publicTreeUri;
    private Uri backupTreeUri;
    private String publicRootPath;
    private String backupRootPath;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        publicTreeUri = parseStoredUri(PREF_PUBLIC_TREE);
        backupTreeUri = parseStoredUri(PREF_BACKUP_TREE);
        refreshStoredRoots();
        requestDir = new File(publicRoot, "config/requests");

        webView = new WebView(this);
        webView.setBackgroundColor(Color.rgb(7, 3, 13));
        webView.setLayoutParams(new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setAllowContentAccess(false);
        settings.setBuiltInZoomControls(false);
        settings.setDisplayZoomControls(false);
        webView.setWebViewClient(new WebViewClient());
        webView.setWebChromeClient(new WebChromeClient());
        webView.addJavascriptInterface(new Bridge(), "Android");
        setContentView(webView);
        webView.loadUrl("file:///android_asset/index.html");
    }

    private Uri parseStoredUri(String key) {
        String value = preferences.getString(key, null);
        return value == null || value.trim().isEmpty() ? null : Uri.parse(value);
    }

    private void refreshStoredRoots() {
        publicRootPath = publicTreeUri == null
                ? new File(Environment.getExternalStorageDirectory(), PUBLIC_ROOT_NAME).getAbsolutePath()
                : DocumentStore.absolutePath(this, publicTreeUri);
        if (publicRootPath == null) {
            publicTreeUri = null;
            preferences.edit().remove(PREF_PUBLIC_TREE).apply();
            publicRootPath = new File(
                    Environment.getExternalStorageDirectory(), PUBLIC_ROOT_NAME).getAbsolutePath();
        } else if (!PUBLIC_ROOT_NAME.equals(new File(publicRootPath).getName())) {
            publicTreeUri = null;
            preferences.edit().remove(PREF_PUBLIC_TREE).apply();
            publicRootPath = new File(
                    Environment.getExternalStorageDirectory(), PUBLIC_ROOT_NAME).getAbsolutePath();
        }
        backupRootPath = backupTreeUri == null
                ? ""
                : DocumentStore.absolutePath(this, backupTreeUri);
        if (backupRootPath == null) {
            backupTreeUri = null;
            preferences.edit().remove(PREF_BACKUP_TREE).apply();
            backupRootPath = "";
        }
        publicRoot = new File(publicRootPath);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (resultCode != RESULT_OK || data == null || data.getData() == null) {
            return;
        }
        Uri uri = data.getData();
        String absolutePath = DocumentStore.absolutePath(this, uri);
        if (absolutePath == null) {
            Toast.makeText(this, "请选择手机内部存储中的文件夹", Toast.LENGTH_LONG).show();
            return;
        }
        if (requestCode == REQUEST_PUBLIC_STORAGE
                && !PUBLIC_ROOT_NAME.equals(new File(absolutePath).getName())) {
            Toast.makeText(
                    this,
                    "部署文件夹必须选择名为“手机端值班室”的文件夹，不能使用备份文件夹",
                    Toast.LENGTH_LONG).show();
            return;
        }
        int flags = data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        try {
            getContentResolver().takePersistableUriPermission(uri, flags);
        } catch (SecurityException exc) {
            Toast.makeText(this, "系统未授予长期文件夹权限", Toast.LENGTH_LONG).show();
            return;
        }
        if (requestCode == REQUEST_PUBLIC_STORAGE) {
            publicTreeUri = uri;
            publicRootPath = absolutePath;
            publicRoot = new File(publicRootPath);
            requestDir = new File(publicRoot, "config/requests");
            preferences.edit().putString(PREF_PUBLIC_TREE, uri.toString()).apply();
            syncBundleInternal();
            Toast.makeText(this, "部署文件夹已授权并同步", Toast.LENGTH_SHORT).show();
        } else if (requestCode == REQUEST_BACKUP_STORAGE) {
            backupTreeUri = uri;
            backupRootPath = absolutePath;
            preferences.edit().putString(PREF_BACKUP_TREE, uri.toString()).apply();
            Toast.makeText(this, "备份文件夹已授权", Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (webView != null) {
            webView.evaluateJavascript(
                    "typeof refreshEnvironment === 'function' && refreshEnvironment()", null);
        }
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_TERMUX_PERMISSION) {
            boolean granted = grantResults.length > 0
                    && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            if (granted) {
                Toast.makeText(this, "终端调用权限已允许，正在验证", Toast.LENGTH_LONG).show();
                reportTermuxPermissionResult(
                        runActionInternal("probe", "{}", "终端授权验证"));
            } else {
                Toast.makeText(this, "终端调用权限未允许", Toast.LENGTH_LONG).show();
                JSONObject denied = termuxPermissionState();
                try {
                    denied.put("ok", false);
                    denied.put("message", "系统未允许“在 Termux 环境中运行命令”");
                    denied.put("code", "RUN_COMMAND_DENIED");
                } catch (JSONException ignored) {
                }
                reportTermuxPermissionResult(denied.toString());
                showTermuxPermissionDialog("系统权限请求已返回，但权限仍未允许。");
            }
        }
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    private JSONObject storageState() {
        JSONObject state = new JSONObject();
        boolean folderGranted = DocumentStore.hasAccess(this, publicTreeUri);
        try {
            state.put("allFiles", folderGranted);
            state.put("legacyWrite", folderGranted);
            state.put("folderGranted", folderGranted);
            state.put("publicRoot", publicRoot.getAbsolutePath());
            state.put("backupRoot", backupRootPath);
            state.put("canWrite", folderGranted);
        } catch (JSONException ignored) {
        }
        return state;
    }

    private boolean canTermuxDrawOverlays() {
        if (!isPackageInstalled(TERMUX_PACKAGE)) {
            return false;
        }
        try {
            int uid = getPackageManager().getPackageInfo(TERMUX_PACKAGE, 0).applicationInfo.uid;
            AppOpsManager appOps = (AppOpsManager) getSystemService(Context.APP_OPS_SERVICE);
            int mode = appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW, uid, TERMUX_PACKAGE);
            return mode == AppOpsManager.MODE_ALLOWED;
        } catch (Exception exc) {
            return false;
        }
    }

    private boolean hasTermuxCommandPermission() {
        return Build.VERSION.SDK_INT < 23
                || checkSelfPermission(TERMUX_PERMISSION) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean isTermuxPermissionDeclared() {
        if (!isPackageInstalled(TERMUX_PACKAGE)) {
            return false;
        }
        try {
            PackageInfo info = getPackageManager().getPackageInfo(
                    TERMUX_PACKAGE, PackageManager.GET_PERMISSIONS);
            if (info.permissions == null) {
                return false;
            }
            for (PermissionInfo permission : info.permissions) {
                if (TERMUX_PERMISSION.equals(permission.name)) {
                    return true;
                }
            }
        } catch (PackageManager.NameNotFoundException ignored) {
        }
        return false;
    }

    private String termuxPermissionProtection() {
        try {
            PermissionInfo info = getPackageManager().getPermissionInfo(TERMUX_PERMISSION, 0);
            int base = info.protectionLevel & PermissionInfo.PROTECTION_MASK_BASE;
            if (base == PermissionInfo.PROTECTION_DANGEROUS) {
                return "dangerous";
            }
            if (base == PermissionInfo.PROTECTION_SIGNATURE) {
                return "signature";
            }
            if (base == PermissionInfo.PROTECTION_SIGNATURE_OR_SYSTEM) {
                return "signatureOrSystem";
            }
            if (base == PermissionInfo.PROTECTION_NORMAL) {
                return "normal";
            }
            return "other:" + base;
        } catch (PackageManager.NameNotFoundException exc) {
            return "notDeclared";
        }
    }

    private JSONObject termuxPermissionState() {
        JSONObject state = new JSONObject();
        boolean declared = isTermuxPermissionDeclared();
        String protection = termuxPermissionProtection();
        boolean granted = hasTermuxCommandPermission();
        boolean requested = preferences.getBoolean(
                PREF_TERMUX_PERMISSION_REQUESTED, false);
        try {
            state.put("granted", granted);
            state.put("declared", declared);
            state.put("protection", protection);
            state.put("requested", requested);
            state.put("runtimeRequestable",
                    declared && "dangerous".equals(protection));
            state.put("rationale", Build.VERSION.SDK_INT >= 23
                    && declared
                    && shouldShowRequestPermissionRationale(TERMUX_PERMISSION));
        } catch (JSONException ignored) {
        }
        return state;
    }

    private void requestTermuxCommandPermission() {
        if (!isPackageInstalled(TERMUX_PACKAGE)) {
            Toast.makeText(this, "未安装 ZeroTermux", Toast.LENGTH_LONG).show();
            return;
        }
        if (Build.VERSION.SDK_INT < 23 || hasTermuxCommandPermission()) {
            Toast.makeText(this, "终端调用权限已允许，正在验证", Toast.LENGTH_SHORT).show();
            reportTermuxPermissionResult(
                    runActionInternal("probe", "{}", "终端授权验证"));
            return;
        }
        String protection = termuxPermissionProtection();
        if (!isTermuxPermissionDeclared() || !"dangerous".equals(protection)) {
            showTermuxPermissionDialog(
                    "当前安装的 ZeroTermux 没有提供可申请的 RUN_COMMAND 运行权限。\n"
                            + "权限声明：" + protection);
            return;
        }
        boolean alreadyRequested = preferences.getBoolean(
                PREF_TERMUX_PERMISSION_REQUESTED, false);
        if (alreadyRequested
                && !shouldShowRequestPermissionRationale(TERMUX_PERMISSION)) {
            showTermuxPermissionDialog(
                    "系统没有再次显示授权弹窗，通常表示此前选择了拒绝或“禁止后不再询问”。");
            openSettings("termux_permission");
            return;
        }
        preferences.edit().putBoolean(PREF_TERMUX_PERMISSION_REQUESTED, true).apply();
        Toast.makeText(
                this,
                "请在系统弹窗中允许“在 Termux 环境中运行命令”",
                Toast.LENGTH_LONG).show();
        try {
            requestPermissions(
                    new String[]{TERMUX_PERMISSION}, REQUEST_TERMUX_PERMISSION);
        } catch (RuntimeException exc) {
            preferences.edit().remove(PREF_TERMUX_PERMISSION_REQUESTED).apply();
            showTermuxPermissionDialog(
                    "系统无法发起 RUN_COMMAND 权限请求："
                            + exc.getClass().getSimpleName());
        }
    }

    private void reportTermuxPermissionResult(String result) {
        final String script = "window.onTermuxPermissionResult"
                + "&&window.onTermuxPermissionResult("
                + JSONObject.quote(result == null ? "{}" : result) + ")";
        if (webView != null) {
            webView.post(new Runnable() {
                @Override
                public void run() {
                    webView.evaluateJavascript(script, null);
                }
            });
        }
    }

    private void showTermuxPermissionDialog(String reason) {
        String message = reason + "\n\n"
                + "请打开“手机端值班室”的应用信息，进入“权限”或“其他权限”，"
                + "允许“在 Termux 环境中运行命令”或名称含 RUN_COMMAND 的权限。\n\n"
                + "若权限列表中没有这一项，请点“复制终端设置”，按备用方法检查 "
                + "ZeroTermux 的外部命令开关。";
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("需要终端运行权限")
                .setMessage(message)
                .setPositiveButton("打开应用权限", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialogInterface, int which) {
                        openSettings("termux_permission");
                    }
                })
                .setNeutralButton("复制终端设置", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialogInterface, int which) {
                        copyTermuxSetupCommand();
                        showSetupDialog();
                    }
                })
                .setNegativeButton("稍后", null)
                .create();
        dialog.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface dialogInterface) {
                dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                        .setTextColor(Color.rgb(57, 197, 187));
                dialog.getButton(AlertDialog.BUTTON_NEUTRAL)
                        .setTextColor(Color.rgb(208, 92, 255));
            }
        });
        dialog.show();
    }

    private void copyTermuxSetupCommand() {
        String command = "mkdir -p ~/.termux; "
                + "grep -qxF 'allow-external-apps=true' "
                + "~/.termux/termux.properties 2>/dev/null "
                + "|| echo 'allow-external-apps=true' >> ~/.termux/termux.properties; "
                + "termux-reload-settings";
        ClipboardManager clipboard =
                (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        clipboard.setPrimaryClip(ClipData.newPlainText("ZeroTermux", command));
    }

    private boolean ensurePublicStorage() {
        if (publicTreeUri == null || !DocumentStore.hasAccess(this, publicTreeUri)) {
            return false;
        }
        try {
            DocumentStore store = new DocumentStore(this, publicTreeUri);
            String[] dirs = new String[]{
                    "bin", "config", "config/requests", "downloads", "backups", "logs"
            };
            for (String dir : dirs) {
                store.ensureDirectory(dir);
            }
            return true;
        } catch (IOException exc) {
            return false;
        }
    }

    private DocumentStore publicStore() throws IOException {
        if (publicTreeUri == null || !DocumentStore.hasAccess(this, publicTreeUri)) {
            throw new IOException("请先授权部署文件夹");
        }
        return new DocumentStore(this, publicTreeUri);
    }

    private String syncBundleInternal() {
        JSONObject result = new JSONObject();
        try {
            if (!ensurePublicStorage()) {
                result.put("ok", false);
                result.put("message", "请先授权“手机端值班室”部署文件夹。");
                return result.toString();
            }
            copyAssetTree("bin", "bin");
            copyAssetTree("service", "service");
            copyAssetFile("VERSION", "VERSION");
            result.put("ok", true);
            result.put("message", "终端组件已同步");
            result.put("path", publicRoot.getAbsolutePath());
        } catch (Exception exc) {
            try {
                result.put("ok", false);
                result.put("message", "同步失败：" + exc.getMessage());
            } catch (JSONException ignored) {
            }
        }
        return result.toString();
    }

    private void copyAssetTree(String assetPath, String targetPath) throws IOException {
        AssetManager assets = getAssets();
        String[] children = assets.list(assetPath);
        if (children == null || children.length == 0) {
            copyAssetFile(assetPath, targetPath);
            return;
        }
        for (String child : children) {
            String childAsset = assetPath + "/" + child;
            String childTarget = targetPath + "/" + child;
            String[] grandchildren = assets.list(childAsset);
            if (grandchildren != null && grandchildren.length > 0) {
                copyAssetTree(childAsset, childTarget);
            } else {
                copyAssetFile(childAsset, childTarget);
            }
        }
    }

    private void copyAssetFile(String assetPath, String targetPath) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (InputStream input = getAssets().open(assetPath)) {
            byte[] buffer = new byte[32768];
            int read;
            while ((read = input.read(buffer)) != -1) {
                output.write(buffer, 0, read);
            }
        }
        publicStore().writeBytes(targetPath, output.toByteArray());
    }

    private File writeRequest(String action, String payload) throws IOException {
        if (!ensurePublicStorage()) {
            throw new IOException("请先授权部署文件夹");
        }
        String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.US).format(new Date());
        String relativePath = "config/requests/" + action + "-" + stamp + ".json";
        byte[] bytes = (payload == null || payload.trim().isEmpty() ? "{}" : payload)
                .getBytes(StandardCharsets.UTF_8);
        publicStore().writeBytes(relativePath, bytes);
        File request = new File(publicRoot, relativePath);
        return request;
    }

    private String runActionInternal(String action, String payload, String label) {
        JSONObject result = new JSONObject();
        try {
            syncBundleInternal();
            File request = writeRequest(action, payload);
            File script = new File(publicRoot, "bin/zbs.sh");
            if (!script.isFile()) {
                throw new IOException("终端脚本缺失：" + script);
            }
            if (!isPackageInstalled(TERMUX_PACKAGE)) {
                throw new IOException("未检测到 ZeroTermux");
            }
            Intent intent = new Intent();
            intent.setClassName(TERMUX_PACKAGE, TERMUX_SERVICE);
            intent.setAction(TERMUX_ACTION);
            intent.putExtra(EXTRA_PATH, "/data/data/com.termux/files/usr/bin/bash");
            intent.putExtra(EXTRA_ARGUMENTS, new String[]{
                    script.getAbsolutePath(), action, request.getAbsolutePath()
            });
            intent.putExtra(EXTRA_WORKDIR, publicRoot.getAbsolutePath());
            intent.putExtra(EXTRA_RUNNER, "terminal-session");
            intent.putExtra(EXTRA_SESSION_ACTION, "0");
            intent.putExtra(EXTRA_SHELL_NAME,
                    label == null || label.trim().isEmpty() ? action : label.trim());
            intent.putExtra(EXTRA_SHELL_CREATE_MODE, "always");
            intent.putExtra(EXTRA_COMMAND_LABEL,
                    label == null || label.trim().isEmpty() ? action : label.trim());
            startService(intent);
            result.put("ok", true);
            result.put("granted", true);
            result.put("message", "已投递到 ZeroTermux 新会话");
            result.put("request", request.getAbsolutePath());
        } catch (SecurityException exc) {
            try {
                String detail = exc.getClass().getSimpleName()
                        + (exc.getMessage() == null ? "" : ": " + exc.getMessage());
                result.put("ok", false);
                result.put("granted", hasTermuxCommandPermission());
                result.put("message", "ZeroTermux 拒绝调用：" + detail);
                result.put("detail", detail);
                result.put("code", "RUN_COMMAND_DENIED");
            } catch (JSONException ignored) {
            }
        } catch (Exception exc) {
            try {
                result.put("ok", false);
                result.put("message", exc.getMessage() == null ? exc.toString() : exc.getMessage());
                result.put("detail", exc.getClass().getSimpleName()
                        + (exc.getMessage() == null ? "" : ": " + exc.getMessage()));
            } catch (JSONException ignored) {
            }
        }
        return result.toString();
    }

    private boolean isPackageInstalled(String packageName) {
        try {
            getPackageManager().getPackageInfo(packageName, 0);
            return true;
        } catch (PackageManager.NameNotFoundException exc) {
            return false;
        }
    }

    private String readConfig(String name, String fallback) {
        if (publicTreeUri == null || !DocumentStore.hasAccess(this, publicTreeUri)) {
            return fallback;
        }
        try {
            String value = new DocumentStore(this, publicTreeUri).readText("config/" + name);
            return value == null ? fallback : value;
        } catch (IOException exc) {
            return fallback;
        }
    }

    private JSONObject readJsonConfig(String name) {
        try {
            return new JSONObject(readConfig(name, "{}"));
        } catch (JSONException exc) {
            return new JSONObject();
        }
    }

    private String loadRuntimeStatesInternal() {
        JSONObject state = new JSONObject();
        try {
            state.put("napcat", readJsonConfig("napcat-runtime.json"));
            state.put("minilm", readJsonConfig("minilm-runtime.json"));
            state.put("astrbot", readJsonConfig("astrbot-runtime.json"));
            state.put("environment", readJsonConfig("environment.json"));
            state.put("bundle", readJsonConfig("runtime-bundle.json"));
            state.put(
                    "astrbotVersion",
                    readConfig("astrbot.version", "").trim());
        } catch (JSONException ignored) {
        }
        return state.toString();
    }

    private String loadTaskStatusInternal(String requestPath) {
        if (requestPath == null) {
            return "{}";
        }
        String name = new File(requestPath).getName();
        if (name.isEmpty() || name.contains("/") || name.contains("\\")) {
            return "{}";
        }
        return readConfig("status/" + name + ".json", "{}");
    }

    private boolean writeConfig(String name, String content) {
        try {
            if (!ensurePublicStorage()) {
                return false;
            }
            publicStore().writeBytes(
                    "config/" + name, content.getBytes(StandardCharsets.UTF_8));
            return true;
        } catch (IOException exc) {
            return false;
        }
    }

    private String listBackupsInternal(String folderPath) {
        JSONObject result = new JSONObject();
        JSONArray files = new JSONArray();
        try {
            if (backupTreeUri == null || !DocumentStore.hasAccess(this, backupTreeUri)) {
                result.put("ok", false);
                result.put("message", "请先选择并授权备份来源文件夹");
                result.put("folder", folderPath == null ? "" : folderPath.trim());
                result.put("files", files);
                return result.toString();
            }
            List<DocumentStore.Entry> zips =
                    new DocumentStore(this, backupTreeUri).listZipFiles();
            Collections.sort(zips, new Comparator<DocumentStore.Entry>() {
                @Override
                public int compare(DocumentStore.Entry left, DocumentStore.Entry right) {
                    return Long.compare(right.modified, left.modified);
                }
            });
            for (DocumentStore.Entry file : zips) {
                JSONObject item = new JSONObject();
                item.put("name", file.name);
                item.put("path", file.absolutePath);
                item.put("size", file.size);
                item.put("mtime", file.modified);
                files.put(item);
            }
            result.put("ok", true);
            result.put("folder", backupRootPath);
            result.put("files", files);
        } catch (Exception exc) {
            try {
                result.put("ok", false);
                result.put("message", exc.getMessage());
                result.put("files", files);
            } catch (JSONException ignored) {
            }
        }
        return result.toString();
    }

    private boolean isPortOpenInternal(int port, int timeoutMs) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress("127.0.0.1", port), timeoutMs);
            return true;
        } catch (IOException exc) {
            return false;
        }
    }

    private String getLocalHttpInternal(String url, int timeoutMs) {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(url).openConnection();
            connection.setConnectTimeout(timeoutMs);
            connection.setReadTimeout(timeoutMs);
            connection.setRequestMethod("GET");
            int code = connection.getResponseCode();
            InputStream input = code >= 400 ? connection.getErrorStream() : connection.getInputStream();
            String body = "";
            if (input != null) {
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                byte[] buffer = new byte[4096];
                int read;
                while ((read = input.read(buffer)) != -1) {
                    output.write(buffer, 0, read);
                }
                body = output.toString(StandardCharsets.UTF_8.name());
            }
            return "{\"ok\":" + (code >= 200 && code < 400) + ",\"code\":" + code +
                    ",\"body\":" + JSONObject.quote(body) + "}";
        } catch (Exception exc) {
            return "{\"ok\":false,\"code\":0,\"message\":" + JSONObject.quote(exc.toString()) + "}";
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private void openExternal(Intent intent, String missingMessage) {
        try {
            startActivity(intent);
        } catch (ActivityNotFoundException exc) {
            Toast.makeText(this, missingMessage, Toast.LENGTH_LONG).show();
        }
    }

    private void chooseStorageFolder(boolean backupFolder) {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        if (publicTreeUri != null) {
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, publicTreeUri);
        }
        try {
            startActivityForResult(
                    intent, backupFolder ? REQUEST_BACKUP_STORAGE : REQUEST_PUBLIC_STORAGE);
        } catch (ActivityNotFoundException exc) {
            Toast.makeText(this, "系统文件选择器不可用", Toast.LENGTH_LONG).show();
        }
    }

    private void openSettings(String kind) {
        Intent intent;
        switch (kind == null ? "" : kind) {
            case "all_files":
                chooseStorageFolder(false);
                return;
            case "backup_folder":
                chooseStorageFolder(true);
                return;
            case "battery":
                intent = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
                break;
            case "termux":
                intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                intent.setData(Uri.parse("package:" + TERMUX_PACKAGE));
                break;
            case "termux_permission":
                intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                intent.setData(Uri.parse("package:" + getPackageName()));
                break;
            case "termux_overlay":
                Intent overlayWithPackage = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION);
                overlayWithPackage.setData(Uri.parse("package:" + TERMUX_PACKAGE));
                Intent overlayGeneric = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION);
                Intent termuxDetails = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                termuxDetails.setData(Uri.parse("package:" + TERMUX_PACKAGE));
                Intent[] candidates =
                        new Intent[]{overlayWithPackage, overlayGeneric, termuxDetails};
                for (Intent candidate : candidates) {
                    try {
                        startActivity(candidate);
                        Toast.makeText(
                                this,
                                "请允许 ZeroTermux 显示在其他应用上层",
                                Toast.LENGTH_LONG).show();
                        return;
                    } catch (Exception ignored) {
                    }
                }
                Toast.makeText(this, "请在 ZeroTermux 应用信息中开启悬浮窗权限", Toast.LENGTH_LONG).show();
                return;
            default:
                intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                intent.setData(Uri.parse("package:" + getPackageName()));
                break;
        }
        openExternal(intent, "无法打开系统设置");
    }

    private void showSetupDialog() {
        String command = "mkdir -p ~/.termux; "
                + "grep -qxF 'allow-external-apps=true' ~/.termux/termux.properties 2>/dev/null "
                + "|| echo 'allow-external-apps=true' >> ~/.termux/termux.properties; "
                + "termux-reload-settings";
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("ZeroTermux 外部命令开关")
                .setMessage("这是终端侧的第二项条件。若“终端调用授权”已经显示已验证，"
                        + "就不需要重复执行。\n\n在 ZeroTermux 中粘贴并执行：\n\n" + command)
                .setPositiveButton("复制并打开终端", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialogInterface, int which) {
                        copyTermuxSetupCommand();
                        openTermuxInternal();
                    }
                })
                .setNegativeButton("仅复制", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialogInterface, int which) {
                        copyTermuxSetupCommand();
                    }
                })
                .create();
        dialog.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface dialogInterface) {
                dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                        .setTextColor(Color.rgb(57, 197, 187));
            }
        });
        dialog.show();
    }

    private boolean openTermuxInternal() {
        Intent launch = getPackageManager().getLaunchIntentForPackage(TERMUX_PACKAGE);
        if (launch == null) {
            Toast.makeText(this, "未安装 ZeroTermux", Toast.LENGTH_LONG).show();
            return false;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(launch);
        return true;
    }

    private boolean openEdgeInternal(String url) {
        if (url == null || url.trim().isEmpty()) {
            return false;
        }
        Intent edge = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        edge.setPackage(EDGE_PACKAGE);
        edge.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(edge);
            return true;
        } catch (ActivityNotFoundException exc) {
            Intent generic = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            generic.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            openExternal(generic, "未安装 Edge 或可用浏览器");
            return false;
        }
    }

    private static final class DocumentStore {
        private static final class Child {
            final String id;
            final String name;
            final boolean directory;

            Child(String id, String name, boolean directory) {
                this.id = id;
                this.name = name;
                this.directory = directory;
            }
        }

        static final class Entry {
            final String name;
            final String absolutePath;
            final long size;
            final long modified;

            Entry(String name, String absolutePath, long size, long modified) {
                this.name = name;
                this.absolutePath = absolutePath;
                this.size = size;
                this.modified = modified;
            }
        }

        private final Context context;
        private final ContentResolver resolver;
        private final Uri treeUri;
        private final String rootId;
        private final String rootPath;

        DocumentStore(Context context, Uri treeUri) throws IOException {
            if (treeUri == null) {
                throw new IOException("文件夹尚未授权");
            }
            this.context = context;
            this.resolver = context.getContentResolver();
            this.treeUri = treeUri;
            try {
                this.rootId = DocumentsContract.getTreeDocumentId(treeUri);
            } catch (Exception exc) {
                throw new IOException("文件夹授权无效", exc);
            }
            this.rootPath = absolutePath(context, treeUri);
            if (rootPath == null) {
                throw new IOException("请选择手机内部存储中的文件夹");
            }
        }

        static boolean hasAccess(Context context, Uri treeUri) {
            if (treeUri == null) {
                return false;
            }
            try {
                String rootId = DocumentsContract.getTreeDocumentId(treeUri);
                Uri rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId);
                try (Cursor cursor = context.getContentResolver().query(
                        rootUri,
                        new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID},
                        null, null, null)) {
                    return cursor != null && cursor.moveToFirst();
                }
            } catch (Exception exc) {
                return false;
            }
        }

        static String absolutePath(Context context, Uri treeUri) {
            if (treeUri == null) {
                return null;
            }
            try {
                String documentId = DocumentsContract.getTreeDocumentId(treeUri);
                if (documentId.startsWith("primary:")) {
                    String relative = documentId.substring("primary:".length());
                    while (relative.startsWith("/")) {
                        relative = relative.substring(1);
                    }
                    File root = context.getExternalFilesDir(null);
                    File storage = Environment.getExternalStorageDirectory();
                    return relative.isEmpty()
                            ? storage.getAbsolutePath()
                            : new File(storage, relative).getAbsolutePath();
                }
                if (documentId.startsWith("raw:")) {
                    return new File(documentId.substring("raw:".length())).getAbsolutePath();
                }
            } catch (Exception ignored) {
            }
            return null;
        }

        String ensureDirectory(String relativePath) throws IOException {
            String normalized = normalize(relativePath);
            String currentId = rootId;
            if (normalized.isEmpty()) {
                return currentId;
            }
            for (String part : normalized.split("/")) {
                if (part.isEmpty() || ".".equals(part)) {
                    continue;
                }
                Child child = findChild(currentId, part);
                if (child == null) {
                    Uri created = DocumentsContract.createDocument(
                            resolver,
                            documentUri(currentId),
                            DocumentsContract.Document.MIME_TYPE_DIR,
                            part);
                    if (created == null) {
                        throw new IOException("无法创建目录：" + part);
                    }
                    currentId = DocumentsContract.getDocumentId(created);
                } else {
                    if (!child.directory) {
                        throw new IOException("同名文件阻止创建目录：" + part);
                    }
                    currentId = child.id;
                }
            }
            return currentId;
        }

        void writeBytes(String relativePath, byte[] bytes) throws IOException {
            String normalized = normalize(relativePath);
            int slash = normalized.lastIndexOf('/');
            String parentPath = slash < 0 ? "" : normalized.substring(0, slash);
            String name = slash < 0 ? normalized : normalized.substring(slash + 1);
            if (name.isEmpty()) {
                throw new IOException("写入路径无效");
            }
            String parentId = ensureDirectory(parentPath);
            Child child = findChild(parentId, name);
            Uri target;
            if (child == null) {
                target = DocumentsContract.createDocument(
                        resolver,
                        documentUri(parentId),
                        "application/octet-stream",
                        name);
            } else {
                if (child.directory) {
                    throw new IOException("同名目录阻止写入文件：" + name);
                }
                target = documentUri(child.id);
            }
            if (target == null) {
                throw new IOException("无法创建文件：" + name);
            }
            try (OutputStream output = resolver.openOutputStream(target, "wt")) {
                if (output == null) {
                    throw new IOException("无法打开文件：" + name);
                }
                output.write(bytes);
                output.flush();
            }
        }

        String readText(String relativePath) throws IOException {
            Child child = findChild(rootId, normalize(relativePath));
            if (child == null || child.directory) {
                return null;
            }
            try (InputStream input = resolver.openInputStream(documentUri(child.id))) {
                if (input == null) {
                    return null;
                }
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                int read;
                while ((read = input.read(buffer)) != -1) {
                    output.write(buffer, 0, read);
                }
                return output.toString(StandardCharsets.UTF_8.name());
            }
        }

        List<Entry> listZipFiles() throws IOException {
            Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, rootId);
            String[] projection = new String[]{
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED
            };
            List<Entry> result = new ArrayList<>();
            try (Cursor cursor = resolver.query(childrenUri, projection, null, null, null)) {
                if (cursor == null) {
                    return result;
                }
                int idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID);
                int nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
                int typeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE);
                int sizeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE);
                int modifiedColumn =
                        cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
                while (cursor.moveToNext()) {
                    String name = nameColumn < 0 ? "" : cursor.getString(nameColumn);
                    String mime = typeColumn < 0 ? "" : cursor.getString(typeColumn);
                    if (name == null || !name.toLowerCase(Locale.US).endsWith(".zip")
                            || DocumentsContract.Document.MIME_TYPE_DIR.equals(mime)) {
                        continue;
                    }
                    long size = sizeColumn < 0 || cursor.isNull(sizeColumn)
                            ? 0 : cursor.getLong(sizeColumn);
                    long modified = modifiedColumn < 0 || cursor.isNull(modifiedColumn)
                            ? 0 : cursor.getLong(modifiedColumn);
                    result.add(new Entry(
                            name,
                            new File(rootPath, name).getAbsolutePath(),
                            size,
                            modified));
                }
            }
            return result;
        }

        private Child findChild(String parentId, String name) throws IOException {
            String normalized = normalize(name);
            if (normalized.contains("/")) {
                String parent = normalized.substring(0, normalized.lastIndexOf('/'));
                return findChild(ensureDirectory(parent), normalized.substring(normalized.lastIndexOf('/') + 1));
            }
            Uri childrenUri =
                    DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId);
            String[] projection = new String[]{
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
            };
            try (Cursor cursor = resolver.query(childrenUri, projection, null, null, null)) {
                if (cursor == null) {
                    return null;
                }
                int idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID);
                int nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
                int typeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE);
                while (cursor.moveToNext()) {
                    String candidate = nameColumn < 0 ? null : cursor.getString(nameColumn);
                    if (!normalized.equals(candidate)) {
                        continue;
                    }
                    String id = idColumn < 0 ? null : cursor.getString(idColumn);
                    String mime = typeColumn < 0 ? null : cursor.getString(typeColumn);
                    if (id != null) {
                        return new Child(
                                id,
                                candidate,
                                DocumentsContract.Document.MIME_TYPE_DIR.equals(mime));
                    }
                }
            }
            return null;
        }

        private Uri documentUri(String documentId) {
            return DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId);
        }

        private static String normalize(String path) {
            if (path == null) {
                return "";
            }
            String normalized = path.replace('\\', '/').trim();
            while (normalized.startsWith("/")) {
                normalized = normalized.substring(1);
            }
            while (normalized.endsWith("/")) {
                normalized = normalized.substring(0, normalized.length() - 1);
            }
            return normalized;
        }
    }

    public final class Bridge {
        @JavascriptInterface
        public String environment() {
            JSONObject state = new JSONObject();
            try {
                state.put("storage", storageState());
                state.put("termuxInstalled", isPackageInstalled(TERMUX_PACKAGE));
                state.put("termuxOverlay", canTermuxDrawOverlays());
                state.put("termuxCommand", hasTermuxCommandPermission());
                state.put("termuxPermission", termuxPermissionState());
                state.put("edgeInstalled", isPackageInstalled(EDGE_PACKAGE));
                state.put("package", getPackageName());
                state.put("version", "1.3.9");
                JSONObject initialization = readJsonConfig("environment.json");
                state.put("environmentReady", initialization.optBoolean("ready", false));
                state.put("environmentUpdatedAt", initialization.optString("updatedAt", ""));
                if (Build.VERSION.SDK_INT >= 23) {
                    PowerManager power = (PowerManager) getSystemService(Context.POWER_SERVICE);
                    state.put("batteryIgnored", power.isIgnoringBatteryOptimizations(getPackageName()));
                } else {
                    state.put("batteryIgnored", true);
                }
            } catch (JSONException ignored) {
            }
            return state.toString();
        }

        @JavascriptInterface
        public String syncBundle() {
            return syncBundleInternal();
        }

        @JavascriptInterface
        public String runAction(String action, String payload, String label) {
            return runActionInternal(action, payload, label);
        }

        @JavascriptInterface
        public String testTermuxCommand() {
            return runActionInternal("probe", "{}", "终端调用测试");
        }

        @JavascriptInterface
        public boolean openTermux() {
            return openTermuxInternal();
        }

        @JavascriptInterface
        public boolean openEdge(String url) {
            return openEdgeInternal(url);
        }

        @JavascriptInterface
        public void openSettings(String kind) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    MainActivity.this.openSettings(kind);
                }
            });
        }

        @JavascriptInterface
        public void showTermuxSetup() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    MainActivity.this.showSetupDialog();
                }
            });
        }

        @JavascriptInterface
        public void requestTermuxPermission() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    MainActivity.this.requestTermuxCommandPermission();
                }
            });
        }

        @JavascriptInterface
        public void chooseBackupFolder() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    MainActivity.this.chooseStorageFolder(true);
                }
            });
        }

        @JavascriptInterface
        public String loadInstances() {
            return readConfig("instances.json", "{\"instances\":[]}");
        }

        @JavascriptInterface
        public String readNapcatWebuiConfig() {
            return readConfig("napcat-webui.json", "");
        }

        @JavascriptInterface
        public String readNapcatReverseWsConfig() {
            return readConfig("napcat-reverse-ws.json", "");
        }

        @JavascriptInterface
        public String loadRuntimeStates() {
            return loadRuntimeStatesInternal();
        }

        @JavascriptInterface
        public String loadTaskStatus(String requestPath) {
            return loadTaskStatusInternal(requestPath);
        }

        @JavascriptInterface
        public boolean saveInstances(String json) {
            return writeConfig("instances.json", json);
        }

        @JavascriptInterface
        public String listBackups(String folder) {
            return listBackupsInternal(folder);
        }

        @JavascriptInterface
        public boolean portOpen(int port) {
            return isPortOpenInternal(port, 350);
        }

        @JavascriptInterface
        public String localHttp(String url) {
            return getLocalHttpInternal(url, 1200);
        }

        @JavascriptInterface
        public void copyText(String text) {
            ClipboardManager clipboard =
                    (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            clipboard.setPrimaryClip(ClipData.newPlainText("手机端值班室", text));
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    Toast.makeText(MainActivity.this, "已复制", Toast.LENGTH_SHORT).show();
                }
            });
        }
    }
}
