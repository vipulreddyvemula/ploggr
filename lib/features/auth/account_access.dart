import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import 'session/session_api.dart';
import 'session/session_controller.dart';

final accountOptions = FutureProvider.autoDispose(
  (ref) async => await ref.watch(sessionApiProvider)?.options() ?? {},
  retry: (_, _) => null,
);

class AccountMethods extends ConsumerStatefulWidget {
  const AccountMethods({super.key, required this.email, required this.login});
  final String Function() email;
  final bool login;
  @override
  ConsumerState<AccountMethods> createState() => _MethodsState();
}

class _MethodsState extends ConsumerState<AccountMethods> {
  bool busy = false;
  String? error;
  Future<void> external(String method, Map options) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final connection = {
        'google': 'google-oauth2',
        'apple': 'apple',
        'phone': 'sms',
      }[method]!;
      final r = await const FlutterAppAuth().authorize(
        AuthorizationRequest(
          options['clientId'],
          'com.example.ploggr.auth://callback',
          issuer: options['issuer'],
          scopes: const ['openid', 'profile', 'email', 'phone'],
          additionalParameters: {'connection': connection},
        ),
      );
      if (!mounted) return;
      await ref
          .read(sessionControllerProvider.notifier)
          .external(r.authorizationCode!, r.codeVerifier!);
    } on FlutterAppAuthUserCancelledException {
      return;
    } on AuthRequestFailure catch (e) {
      if (mounted) {
        setState(
          () => error = e.status == 409
              ? 'Use the sign-in method you used to create this account.'
              : 'Could not sign in. Please retry.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not complete sign-in. Please retry.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opts = ref.watch(accountOptions);
    final options = opts.value ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.login && options['recovery'] == true)
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PasswordRecovery(widget.email()),
              ),
            ),
            child: const Text('Forgot password?'),
          ),
        for (final m in (options['methods'] as List? ?? []))
          OutlinedButton(
            onPressed: busy ? null : () => external(m, options),
            child: Text(
              'Continue with ${{'google': 'Google', 'apple': 'Apple', 'phone': 'phone'}[m]}',
            ),
          ),
        if (opts.hasError)
          TextButton(
            onPressed: () => ref.invalidate(accountOptions),
            child: const Text('Retry loading sign-in options'),
          ),
        if (error != null) Text(error!),
      ],
    );
  }
}

class PasswordRecovery extends ConsumerStatefulWidget {
  const PasswordRecovery(this.email, {super.key});
  final String email;
  @override
  ConsumerState<PasswordRecovery> createState() => _RecoveryState();
}

class _RecoveryState extends ConsumerState<PasswordRecovery> {
  late final email = TextEditingController(text: widget.email);
  final code = TextEditingController(), password = TextEditingController();
  bool requested = false, busy = false;
  String? notice;
  @override
  void dispose() {
    email.dispose();
    code.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> send(bool reset) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      final api = ref.read(sessionApiProvider)!;
      if (reset) {
        await api.reset(email.text.trim(), code.text.trim(), password.text);
        if (mounted) {
          toast(context, 'Password reset. Log in with your new password.');
          Navigator.pop(context);
        }
      } else {
        await api.requestReset(email.text.trim());
        if (mounted) {
          setState(() {
            requested = true;
            notice =
                'If this email has a password account, an eight-digit code will arrive shortly.';
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => notice = reset
              ? 'Check the code, email and new password. Request a fresh code if it expired.'
              : 'Could not request a code. Retry when connected.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppPage(
    title: 'Reset password',
    child: AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppField(
            label: 'Email',
            icon: Icons.email_outlined,
            controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
          ),
          if (requested) ...[
            AppField(
              label: 'Eight-digit code',
              icon: Icons.pin_outlined,
              controller: code,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
            ),
            AppField(
              label: 'New password',
              icon: Icons.lock_outline,
              password: true,
              controller: password,
              helper: 'Use 15–128 characters.',
              autofillHints: const [AutofillHints.newPassword],
            ),
            TextButton(
              onPressed: busy ? null : () => send(false),
              child: const Text('Request new code'),
            ),
          ],
          if (notice != null) Semantics(liveRegion: true, child: Text(notice!)),
          PrimaryButton(
            busy
                ? 'Please wait…'
                : requested
                ? 'Reset password'
                : 'Send reset code',
            onPressed: busy ? null : () => send(requested),
          ),
        ],
      ),
    ),
  );
}
