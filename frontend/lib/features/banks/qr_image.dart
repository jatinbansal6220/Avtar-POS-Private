import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// QR artwork is retained as a small square PNG inside the authenticated bank
/// record. Keeping it in JSON makes it work offline and on every terminal;
/// no public file URL or extra storage permission is needed.
String compressQrImage(Uint8List sourceBytes) {
  final source = image.decodeImage(sourceBytes);
  if (source == null) {
    throw FormatException('Choose a valid PNG, JPG, or WebP QR image.');
  }
  const canvasSize = 320;
  final scale = math.min(canvasSize / source.width, canvasSize / source.height);
  final resized = image.copyResize(
    source,
    width: math.max(1, (source.width * scale).round()),
    height: math.max(1, (source.height * scale).round()),
  );
  final canvas = image.Image(canvasSize, canvasSize);
  image.fill(canvas, image.getColor(255, 255, 255));
  image.copyInto(
    canvas,
    resized,
    dstX: (canvasSize - resized.width) ~/ 2,
    dstY: (canvasSize - resized.height) ~/ 2,
  );
  final encoded = image.encodePng(canvas, level: 6);
  if (encoded.length > 180000) {
    throw FormatException(
      'QR image is too large after compression. Use a clear square QR image.',
    );
  }
  return base64Encode(encoded);
}

Uint8List? qrImageBytes(dynamic encoded) {
  final text = '${encoded ?? ''}'.trim();
  if (text.isEmpty) return null;
  try {
    return Uint8List.fromList(base64Decode(text));
  } catch (_) {
    return null;
  }
}
