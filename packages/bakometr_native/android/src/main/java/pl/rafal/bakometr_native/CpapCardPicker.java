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
 * Wybór karty SD aparatu ResMed (Storage Access Framework) i skopiowanie jej danych do pamięci aplikacji
 * (files/cpap, ta sama struktura co na karcie): STR.edf, Identification.*, DATALOG/RRRRMMDD/*.edf
 * (BRP — pełny przepływ i ciśnienie 25 Hz, PLD — przebiegi co 2 s, EVE/CSL — zdarzenia, SAD/SA2 — oksymetria).
 * Kopiowanie przyrostowe: pliki o tej samej wielkości są pomijane. Pliki BRP tylko od dnia [waveFrom].
 */
class CpapCardPicker implements PluginRegistry.ActivityResultListener {
    private static final int REQ = 4712;
    private final Context ctx;
    private MethodChannel.Result pending;
    private String waveFrom = "00000000";
    private final Handler main = new Handler(Looper.getMainLooper());

    CpapCardPicker(Context ctx) {
        this.ctx = ctx;
    }

    void pick(Activity activity, String waveFromDay, MethodChannel.Result result) {
        if (activity == null) {
            result.error("no_activity", "Brak aktywności", null);
            return;
        }
        if (pending != null) pending.success(null);
        pending = result;
        waveFrom = waveFromDay != null ? waveFromDay : "00000000";
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
            int[] stats = new int[2]; // [znalezione, pominięte bez zmian]
            String error = null;
            boolean found = false;
            try {
                found = copyAll(tree, out, stats);
            } catch (Exception e) {
                error = e.toString();
            }
            final String err = error;
            final boolean ok = found;
            main.post(() -> {
                if (out.isEmpty() && err != null) {
                    r.error("copy", err, null);
                    return;
                }
                java.util.HashMap<String, Object> m = new java.util.HashMap<>();
                m.put("root", new File(ctx.getFilesDir(), "cpap").getAbsolutePath());
                m.put("copied", out);
                m.put("found", ok);
                m.put("files", stats[0]);
                m.put("unchanged", stats[1]);
                r.success(m);
            });
        });
        return true;
    }

    private static class Doc {
        final String id, name, mime;
        final long size;
        Doc(String id, String name, String mime, long size) {
            this.id = id;
            this.name = name;
            this.mime = mime;
            this.size = size;
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
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE}, null, null, null)) {
            if (c == null) return out;
            while (c.moveToNext()) {
                long size = c.isNull(3) ? -1 : c.getLong(3);
                out.add(new Doc(c.getString(0), c.getString(1), c.getString(2), size));
            }
        }
        return out;
    }

    /** Zwraca true, gdy wskazany folder wygląda na kartę ResMed (STR.edf lub DATALOG). */
    private boolean copyAll(Uri tree, List<String> out, int[] stats) throws Exception {
        // dawny katalog tymczasowy
        deleteRec(new File(ctx.getCacheDir(), "cpap_sd"));
        File root = new File(ctx.getFilesDir(), "cpap");
        //noinspection ResultOfMethodCallIgnored
        root.mkdirs();
        String rootId = DocumentsContract.getTreeDocumentId(tree);
        List<Doc> top = children(tree, rootId);
        Doc datalog = null;
        boolean found = false;
        for (Doc d : top) {
            String n = d.name == null ? "" : d.name;
            String u = n.toUpperCase();
            if (!d.isDir() && (u.equals("STR.EDF") || u.startsWith("IDENTIFICATION."))) {
                found |= u.equals("STR.EDF");
                copyIfChanged(tree, d, root, n, out, stats);
            }
            if (d.isDir() && u.equals("DATALOG")) datalog = d;
        }
        // Użytkownik mógł wskazać sam folder DATALOG
        if (datalog == null && top.stream().anyMatch(d -> d.isDir() && d.name != null && d.name.matches("\\d{8}"))) {
            datalog = new Doc(rootId, "DATALOG", DocumentsContract.Document.MIME_TYPE_DIR, -1);
        }
        if (datalog == null) return found;
        found = true;
        File dl = new File(root, "DATALOG");
        for (Doc day : children(tree, datalog.id)) {
            if (!day.isDir() || day.name == null || !day.name.matches("\\d{8}")) continue;
            boolean waves = day.name.compareTo(waveFrom) >= 0;
            File dir = new File(dl, day.name);
            for (Doc f : children(tree, day.id)) {
                String n = f.name == null ? "" : f.name;
                String u = n.toUpperCase();
                if (!u.endsWith(".EDF")) continue;
                if (u.contains("_BRP") && !waves) continue;
                //noinspection ResultOfMethodCallIgnored
                dir.mkdirs();
                copyIfChanged(tree, f, dir, n, out, stats);
            }
        }
        return found;
    }

    private void copyIfChanged(Uri tree, Doc d, File dir, String name, List<String> out, int[] stats) throws Exception {
        stats[0]++;
        File f = new File(dir, name);
        if (f.exists() && d.size >= 0 && f.length() == d.size) {
            stats[1]++;
            return;
        }
        Uri uri = DocumentsContract.buildDocumentUriUsingTree(tree, d.id);
        File tmp = new File(dir, name + ".part");
        try (InputStream in = ctx.getContentResolver().openInputStream(uri);
             OutputStream os = new FileOutputStream(tmp)) {
            if (in == null) throw new Exception("Nie można otworzyć " + name);
            byte[] buf = new byte[65536];
            int r;
            while ((r = in.read(buf)) > 0) os.write(buf, 0, r);
        }
        //noinspection ResultOfMethodCallIgnored
        f.delete();
        if (!tmp.renameTo(f)) throw new Exception("Nie można zapisać " + name);
        out.add(f.getAbsolutePath());
    }

    private static void deleteRec(File f) {
        if (f == null || !f.exists()) return;
        File[] list = f.listFiles();
        if (list != null) for (File c : list) deleteRec(c);
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }
}
