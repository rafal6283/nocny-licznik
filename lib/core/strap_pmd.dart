import 'dart:typed_data';

/// Polar PMD (H10): akcelerometr 25 Hz, ±8 g, 16 bit – komendy i odczyt ramek (także z kompresją delta).
const List<int> pmdStartAcc = [0x02, 0x02, 0x00, 0x01, 25, 0x00, 0x01, 0x01, 0x10, 0x00, 0x02, 0x01, 0x08, 0x00];
const List<int> pmdStopAcc = [0x03, 0x02];

/// Próbki x,y,z w mG (przeplatane) albo null, gdy to nie ramka ACC.
List<int>? parseAccFrame(List<int> data) {
  if (data.length < 10 || data[0] != 0x02) return null;
  final bytes = Uint8List.fromList(data);
  final frameType = bytes[9];
  final compressed = frameType & 0x80 != 0;
  final width = (frameType & 0x7F) + 1; // bajty na oś
  final out = <int>[];
  int readSigned(int off, int nBytes) {
    var v = 0;
    for (var k = 0; k < nBytes; k++) {
      v |= bytes[off + k] << (8 * k);
    }
    final bits = 8 * nBytes;
    if (v & (1 << (bits - 1)) != 0) v -= 1 << bits;
    return v;
  }

  if (!compressed) {
    for (var i = 10; i + 3 * width <= bytes.length; i += 3 * width) {
      for (var c = 0; c < 3; c++) {
        out.add(readSigned(i + c * width, width));
      }
    }
    return out;
  }

  // Kompresja delta (jak w Polar BLE SDK): próbka odniesienia (16 bit/oś),
  // potem bloki [szerokość delty w bitach][liczba próbek][dane bitowe LSB-first].
  var off = 10;
  if (off + 6 > bytes.length) return null;
  final ref = [for (var c = 0; c < 3; c++) readSigned(off + 2 * c, 2)];
  off += 6;
  out.addAll(ref);
  final cur = [...ref];
  while (off + 2 <= bytes.length) {
    final deltaBits = bytes[off], count = bytes[off + 1];
    off += 2;
    if (deltaBits == 0 || count == 0) break;
    final totalBits = deltaBits * 3 * count;
    final nBytes = (totalBits + 7) ~/ 8;
    if (off + nBytes > bytes.length) break;
    var bitPos = 0;
    int readBits() {
      var v = 0;
      for (var b = 0; b < deltaBits; b++) {
        final byte = bytes[off + ((bitPos + b) >> 3)];
        if ((byte >> ((bitPos + b) & 7)) & 1 == 1) v |= 1 << b;
      }
      bitPos += deltaBits;
      if (v & (1 << (deltaBits - 1)) != 0) v -= 1 << deltaBits;
      return v;
    }

    for (var s = 0; s < count; s++) {
      for (var c = 0; c < 3; c++) {
        cur[c] += readBits();
        out.add(cur[c]);
      }
    }
    off += nBytes;
  }
  return out;
}
