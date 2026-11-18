import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../shared/widgets/eco_art.dart';
import 'session/session_api.dart';
import 'session/session_controller.dart';

class AccountForm extends ConsumerStatefulWidget {
  const AccountForm({super.key, required this.signup});
  final bool signup;

  @override
  ConsumerState<AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends ConsumerState<AccountForm> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy ||
        ref.read(sessionControllerProvider).phase != SessionPhase.signedOut ||
        !_form.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final session = ref.read(sessionControllerProvider.notifier);
    try {
      final authenticate = widget.signup ? session.signup : session.login;
      await authenticate(_email.text.trim(), _password.text);
      // The router observes the session only after secure storage succeeds.
    } on AuthRequestFailure catch (failure) {
      if (!mounted) return;
      _error = switch (failure.status) {
        400 => 'Check your email and password and try again.',
        401 => 'Incorrect email or password.',
        409 => 'An account already uses this email. Try logging in.',
        null => 'Cannot reach the server. Check your connection and retry.',
        _ => 'Sign-in service unavailable. Please try again.',
      };
    } catch (_) {
      if (mounted) {
        _error = 'Could not establish a secure session. Please retry.';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signup = widget.signup;
    final ready =
        ref.watch(sessionControllerProvider).phase == SessionPhase.signedOut;
    return AppPage(
      title: '',
      backTo: signup ? AppRoutes.login : AppRoutes.onboarding,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: PloggrLogo(size: 70)),
            const SizedBox(height: 24),
            Text(signup ? 'Sign Up' : 'Welcome back!', style: AppText.title),
            const SizedBox(height: 24),
            AppField(
              label: 'Email',
              icon: Icons.mail_outline_rounded,
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              validator: (value) {
                final email = (value ?? '').trim();
                return email.runes.length <= 254 &&
                        RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)
                    ? null
                    : 'Enter a valid email address';
              },
            ),
            const SizedBox(height: 14),
            AppField(
              label: 'Password',
              icon: Icons.lock_outline_rounded,
              password: true,
              controller: _password,
              textInputAction: signup
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: signup ? null : (_) => _submit(),
              validator: (value) {
                final length = (value ?? '').runes.length;
                if (length > 128) return 'Use at most 128 characters';
                if (signup && length < 15) return 'Use at least 15 characters';
                return length == 0 ? 'Enter your password' : null;
              },
            ),
            if (signup) ...[
              const SizedBox(height: 14),
              AppField(
                label: 'Confirm Password',
                icon: Icons.lock_outline_rounded,
                password: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                validator: (value) =>
                    value == _password.text ? null : 'Passwords must match',
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(_error!)),
              ),
            const SizedBox(height: 24),
            PrimaryButton(
              _busy
                  ? (signup ? 'Creating account…' : 'Logging in…')
                  : (signup ? 'Create Account' : 'Login'),
              onPressed: ready && !_busy ? _submit : null,
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => switchPage(
                      context,
                      signup ? AppRoutes.login : AppRoutes.signup,
                    ),
              child: Text(signup ? 'Login' : 'Sign up'),
            ),
          ],
        ),
      ),
    );
  }
}
