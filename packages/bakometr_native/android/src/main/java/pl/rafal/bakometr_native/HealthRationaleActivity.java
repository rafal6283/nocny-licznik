package pl.rafal.bakometr_native;

import android.app.Activity;
import android.os.Bundle;
import android.widget.ScrollView;
import android.widget.TextView;

/** Wymagane przez Health Connect: wyjaśnienie, po co aplikacji dostęp do danych zdrowotnych. */
public class HealthRationaleActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setTitle("Nocny Licznik i Health Connect");
        TextView t = new TextView(this);
        int pad = (int) (20 * getResources().getDisplayMetrics().density);
        t.setPadding(pad, pad, pad, pad);
        t.setTextSize(16);
        t.setText("Nocny Licznik tylko zapisuje w Health Connect Twoje noce: początek i koniec snu oraz "
                + "fazy snu (czuwanie, płytki, głęboki, REM), z krótką notatką (np. o chrapaniu).\n\n"
                + "Dzięki temu inne aplikacje, którym na to pozwolisz (np. Life Cycle), widzą Twój sen.\n\n"
                + "Aplikacja nie czyta żadnych danych z Health Connect i niczego nie wysyła do internetu. "
                + "Zapis wyłączysz w Ustawieniach aplikacji, a dostęp odbierzesz w Health Connect.");
        ScrollView s = new ScrollView(this);
        s.addView(t);
        setContentView(s);
    }
}
