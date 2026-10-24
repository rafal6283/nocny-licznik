package pl.rafal.bakometr_native;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;

import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Wybór karty SD aparatu ResMed (Storage Access Framework) i skopiowanie potrzebnych plików:
 * STR.edf oraz DATALOG/RRRRMMDD/*_EVE.edf i *_PLD.edf z zakresu dat. Duże *_BRP.edf są pomijane.
 */
class CpapCardPicker implements PluginRegistry.ActivityResultListener {
    private static final int REQ = 4712;
    private final Context ctx;
    private MethodChannel.Result pending;
    private String fromDay = "00000000", toDay = "99999999";
    private final Handler main = new Handler(Looper.getMainLooper());

    CpapCardPicker(Context ctx) {
        this.ctx = ctx;
    }

    void pick(Activity activity, String from, String to, MethodChannel.Result result) {
        if (activity == null) {
            result.error("no_activity", "Brak aktywności", null);
            return;
        }
        if (pending != null) pending.success(null);
        pending = result;
        fromDay = from != null ? from : "00000000";
        toDay = to != null ? to : "99999999";
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        activity.startActivityForResult(i, REQ);
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQ) return false;
        final MethodChannel.Result r = pending;
        pending = null;
        if (r == null) return true;
        if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
            r.success(null);
            return true;
        }
        final Uri tree = data.getData();
        Executors.newSingleThreadExecutor().execute(() -> {
            List<String> out = new ArrayList<>();
            String error = null;
            try {
                copyAll(tree, out);
            } catch (Exception e) {
                error = e.toString();
            }
            final String err = error;
            main.post(() -> {
                if (out.isEmpty() && err != null) r.error("copy", err, null);
                else r.success(out);
            });
        });
        return true;
    }

    private static class Doc {
        final String id, name, mime;
        Doc(String id, String name, String mime) {
            this.id = id;
            this.name = name;
            this.mime = mime;
        }
        boolean isDir() {
            return DocumentsContract.Document.MIME_TYPE_DIR.equals(mime);
        }
    }

    private List<Doc> children(Uri tree, String parentId) {
        List<Doc> out = new ArrayList<>();
        Uri uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId);
        ContentResolver cr = ctx.getContentResolver();
        try (Cursor c = cr.query(uri, new String[]{
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE}, null, null, null)) {
            if (c == null) return out;
            while (c.moveToNext()) out.add(new Doc(c.getString(0), c.getString(1), c.getString(2)));
        }
        return out;
    }

    private void copyAll(Uri tree, List<String> out) throws Exception {
        File dir = new File(ctx.getCacheDir(), "cpap_sd");
        deleteRec(dir);
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        String rootId = DocumentsContract.getTreeDocumentId(tree);
        List<Doc> root = children(tree, rootId);
        Doc datalog = null;
        for (Doc d : root) {
            String n = d.name == null ? "" : d.name;
            if (!d.isDir() && n.equalsIgnoreCase("STR.edf")) out.add(copy(tree, d, dir, n));
            if (d.isDir() && n.equalsIgnoreCase("DATALOG")) datalog = d;
        }
        // Użytkownik mógł wskazać sam folder DATALOG
        if (datalog == null && root.stream().anyMatch(d -> d.isDir() && d.name != null && d.name.matches("\\d{8}"))) {
            datalog = new Doc(rootId, "DATALOG", DocumentsContract.Document.MIME_TYPE_DIR);
        }
        if (datalog == null) return;
        for (Doc day : children(tree, datalog.id)) {
            if (!day.isDir() || day.name == null || !day.name.matches("\\d{8}")) continue;
            if (day.name.compareTo(fromDay) < 0 || day.name.compareTo(toDay) > 0) continue;
            for (Doc f : children(tree, day.id)) {
                String n = f.name == null ? "" : f.name;
                String u = n.toUpperCase();
                if (u.endsWith("_EVE.EDF") || u.endsWith("_PLD.EDF")) out.add(copy(tree, f, dir, n));
            }
        }
    }

    private String copy(Uri tree, Doc d, File dir, String name) throws Exception {
        Uri uri = DocumentsContract.buildDocumentUriUsingTree(tree, d.id);
        File f = new File(dir, name);
        try (InputStream in = ctx.getContentResolver().openInputStream(uri);
             OutputStream os = new FileOutputStream(f)) {
            if (in == null) throw new Exception("Nie można otworzyć " + name);
            byte[] buf = new byte[65536];
            int r;
            while ((r = in.read(buf)) > 0) os.write(buf, 0, r);
        }
        return f.getAbsolutePath();
    }

    private static void deleteRec(File f) {
        if (f == null || !f.exists()) return;
        File[] list = f.listFiles();
        if (list != null) for (File c : list) deleteRec(c);
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }
}
