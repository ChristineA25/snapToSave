
// lib/shop_stamp.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class ShopStamp {
  /// Returns a PNG with a compact banner "Shop: <shopName>  |  ID: <shopID>"
  static Future<Uint8List> stamp({
    required Uint8List srcPngOrJpgBytes,
    required String shopName,
    required String shopID,
    Alignment align = Alignment.bottomLeft,
    double padding = 16,
    double bannerOpacity = 0.6,
  }) async {
    // Decode source
    final codec = await ui.instantiateImageCodec(srcPngOrJpgBytes);
    final frame = await codec.getNextFrame();
    final ui.Image base = frame.image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(base.width.toDouble(), base.height.toDouble());

    // Draw original
    canvas.drawImage(base, Offset.zero, Paint());

    // Compose single line text
    final line = 'Shop: $shopName   |   ID: $shopID';

    final fontPx = (size.shortestSide / 28).clamp(14.0, 36.0);
    final ts = ui.TextStyle(
      color: Colors.white,
      fontSize: fontPx,
      fontWeight: ui.FontWeight.w600,
    );
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      maxLines: 1,
      ellipsis: '…',
    ))
      ..pushStyle(ts)
      ..addText(line);
    final paragraph = pb.build()
      ..layout(ui.ParagraphConstraints(width: size.width - padding * 2));

    final textH = paragraph.height;
    final bannerH = textH + padding * 2;

    // Banner rect
    final rect = Rect.fromLTWH(
      0,
      align == Alignment.topLeft ? 0 : (size.height - bannerH),
      size.width,
      bannerH,
    );
    final bg = Paint()..color = Colors.black.withOpacity(bannerOpacity);
    canvas.drawRect(rect, bg);

    // Text position
    final dx = padding;
    final dy = align == Alignment.topLeft ? padding : (size.height - bannerH + padding);
    canvas.drawParagraph(paragraph, Offset(dx, dy));

    final pic = recorder.endRecording();
    final out = await pic.toImage(base.width, base.height);
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }
}
