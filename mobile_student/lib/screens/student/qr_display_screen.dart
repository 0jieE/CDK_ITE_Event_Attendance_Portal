import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../models/event.dart';
import '../../models/qr_slot.dart';
import '../../widgets/qr_code_view.dart';

/// Full-screen, high-contrast **daily** QR for the instructor to scan.
///
/// Always black-on-white regardless of the app theme so it scans reliably. The
/// raw token is never shown as text. (Screen brightness / keep-awake are left
/// to the system: doing them needs a native plugin.)
class QrDisplayScreen extends StatefulWidget {
  final QrSlot slot;
  final Event event;
  const QrDisplayScreen({super.key, required this.slot, required this.event});

  @override
  State<QrDisplayScreen> createState() => _QrDisplayScreenState();
}

class _QrDisplayScreenState extends State<QrDisplayScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final schedule = widget.event.schedule;
    final media = MediaQuery.of(context);
    // Large, but never taller than the screen leaves room for.
    final size = (media.size.width - 48 - 24)
        .clamp(200.0, media.size.height * 0.55)
        .toDouble();
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
              child: Column(
                children: [
                  Text(widget.event.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF17231A))),
                  const SizedBox(height: 6),
                  Text(
                    DateFormat('EEEE, MMM d, y').format(slot.date),
                    style: const TextStyle(
                        fontSize: 16, color: Color(0xFF5B6B5F)),
                  ),
                  const SizedBox(height: 20),
                  QrCodeView(data: slot.token, size: size, padding: 12),
                  const SizedBox(height: 20),
                  const Text('Daily Attendance QR',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF17231A))),
                  const SizedBox(height: 4),
                  const Text(
                    'Show this code to your instructor during each slot window.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF5B6B5F)),
                  ),
                  if (schedule.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F6F3),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Scan windows',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2B8416))),
                          const SizedBox(height: 6),
                          ...schedule.map(
                            (w) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(w.label,
                                      style: const TextStyle(
                                          color: Color(0xFF5B6B5F))),
                                  Text('${w.start} – ${w.end}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF17231A))),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton.filledTonal(
                tooltip: 'Close',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFE9EEE9),
                  foregroundColor: const Color(0xFF17231A),
                ),
                icon: const Icon(Icons.close, size: 26),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
