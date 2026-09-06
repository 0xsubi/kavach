import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A QR code rendered for a phone camera to read off another screen.
///
/// Colors are hardcoded black-on-white rather than pulled from
/// [KavachColors], deliberately: scanners expect dark modules on a light
/// field, and a QR that silently stopped scanning because someone
/// retuned a palette token would be a miserable bug to track down. The
/// white plate also guarantees the spec's quiet zone survives on any
/// background this is dropped onto.
class KavachQrCode extends StatelessWidget {
  const KavachQrCode({
    super.key,
    required this.data,
    this.size = 200,
    this.semanticLabel,
  });

  /// Payload to encode. Keep it short — QR density climbs with length and
  /// a dense code is harder to read off a glossy screen.
  final String data;

  /// Side length of the code itself, excluding the white plate's padding.
  final double size;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE3E5E8)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: QrImageView(
            data: data,
            version: QrVersions.auto,
            size: size,
            backgroundColor: Colors.white,
            // Medium error correction: enough redundancy to survive screen
            // glare and moire without inflating the module count the way
            // Q/H would.
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            gapless: true,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Colors.black,
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Colors.black,
            ),
            // Payloads over the format's capacity throw inside the painter
            // otherwise, taking the whole dialog down with them.
            errorStateBuilder: (context, error) => SizedBox(
              width: size,
              height: size,
              child: const Center(
                child: Text(
                  'could not render QR — use the values below',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF8A8F98), fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
