package pl.rafal.bakometr_native;

import android.content.Context;
import android.content.Intent;
import android.media.AudioFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;

import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.util.ArrayList;

import io.flutter.plugin.common.MethodChannel;

/**
 * Rozpoznawanie mowy z nagrania (mówienie przez sen) systemowym rozpoznawaniem mowy,
 * z preferencją pracy na telefonie. Wymaga Androida 13 (dźwięk podawany z pliku).
 */
final class SpeechTranscriber {
    private SpeechTranscriber() {}

    static void transcribe(Context ctx, String wavPath, String lang, MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.error("sdk", "Zamiana mowy na tekst z nagrań wymaga Androida 13 lub nowszego.", null);
            return;
        }
        if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
            result.error("unavailable", "Brak systemowego rozpoznawania mowy (zainstaluj/aktualizuj aplikację Google).", null);
            return;
        }
        final File pcm;
        final int rate, channels;
        try (RandomAccessFile f = new RandomAccessFile(wavPath, "r")) {
            byte[] b = new byte[(int) f.length()];
            f.readFully(b);
            int p = 12, r = 16000, ch = 1, dataOff = -1, dataLen = 0;
            while (p + 8 <= b.length) {
                String id = new String(b, p, 4, "US-ASCII");
                int len = (b[p + 4] & 0xff) | ((b[p + 5] & 0xff) << 8) | ((b[p + 6] & 0xff) << 16) | ((b[p + 7] & 0xff) << 24);
                if (id.equals("fmt ")) {
                    ch = (b[p + 10] & 0xff) | ((b[p + 11] & 0xff) << 8);
                    r = (b[p + 12] & 0xff) | ((b[p + 13] & 0xff) << 8) | ((b[p + 14] & 0xff) << 16) | ((b[p + 15] & 0xff) << 24);
                } else if (id.equals("data")) {
                    dataOff = p + 8;
                    dataLen = Math.min(len, b.length - dataOff);
                    break;
                }
                p += 8 + len + (len % 2);
            }
            if (dataOff < 0) throw new Exception("Nieprawidłowy plik WAV");
            rate = r;
            channels = ch;
            pcm = new File(ctx.getCacheDir(), "stt.pcm");
            try (FileOutputStream os = new FileOutputStream(pcm)) {
                os.write(b, dataOff, dataLen);
                // chwila ciszy na końcu, żeby rozpoznawanie domknęło wypowiedź
                os.write(new byte[rate * channels * 2]);
            }
        } catch (Exception e) {
            result.error("file", e.toString(), null);
            return;
        }
        final Handler main = new Handler(Looper.getMainLooper());
        main.post(() -> {
            final boolean[] done = {false};
            final SpeechRecognizer sr = SpeechRecognizer.createSpeechRecognizer(ctx);
            final ParcelFileDescriptor pfd;
            try {
                pfd = ParcelFileDescriptor.open(pcm, ParcelFileDescriptor.MODE_READ_ONLY);
            } catch (Exception e) {
                sr.destroy();
                result.error("file", e.toString(), null);
                return;
            }
            Runnable finish = () -> {
                try {
                    sr.destroy();
                } catch (Exception ignored) {
                }
                try {
                    pfd.close();
                } catch (Exception ignored) {
                }
            };
            sr.setRecognitionListener(new RecognitionListener() {
                @Override public void onReadyForSpeech(Bundle params) {}
                @Override public void onBeginningOfSpeech() {}
                @Override public void onRmsChanged(float rmsdB) {}
                @Override public void onBufferReceived(byte[] buffer) {}
                @Override public void onEndOfSpeech() {}
                @Override public void onPartialResults(Bundle partialResults) {}
                @Override public void onEvent(int eventType, Bundle params) {}

                @Override
                public void onError(int error) {
                    if (done[0]) return;
                    done[0] = true;
                    finish.run();
                    // brak dopasowania / brak mowy = pusty tekst, nie błąd
                    if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                        result.success("");
                    } else {
                        result.error("stt", "Błąd rozpoznawania mowy (" + error + ")", null);
                    }
                }

                @Override
                public void onResults(Bundle results) {
                    if (done[0]) return;
                    done[0] = true;
                    finish.run();
                    ArrayList<String> r = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                    result.success(r == null || r.isEmpty() ? "" : r.get(0));
                }
            });
            Intent i = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
            i.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
            i.putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang);
            i.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true);
            i.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
            i.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pfd);
            i.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, channels);
            i.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT);
            i.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, rate);
            sr.startListening(i);
            main.postDelayed(() -> {
                if (done[0]) return;
                done[0] = true;
                try {
                    sr.stopListening();
                } catch (Exception ignored) {
                }
                finish.run();
                result.error("timeout", "Rozpoznawanie mowy nie odpowiedziało", null);
            }, 45000);
        });
    }
}
