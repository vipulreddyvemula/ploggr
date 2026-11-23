import 'package:material_ui/material_ui.dart';

import 'session/session_api.dart';
import 'session/session_controller.dart';

Future<void> logoutFromDevice(
  BuildContext context,
  SessionController sessions,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await sessions.logout();
    if (messenger.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Signed out of Ploggr.')),
      );
    }
  } on AuthRequestFailure {
    if (messenger.mounted) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Signed out on this device. Server sign-out could not be confirmed.',
          ),
        ),
      );
    }
  } catch (_) {
    // The session gate offers Retry logout when local deletion fails.
  }
}
