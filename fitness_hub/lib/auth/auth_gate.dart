import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../dev/rules_probe.dart';
import '../home/dashboard_shell.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import 'login_page.dart';

/// Decides what to show:
/// not signed in -> Login | signed in but no active role -> Access denied
/// | signed in with active role -> Dashboard shell.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: authService.authChanges,
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const _Splash();
        }
        final user = authSnap.data;
        if (user == null) return const LoginPage();

        return StreamBuilder<StaffProfile?>(
          stream: authService.profileStream(user.uid),
          builder: (context, profSnap) {
            if (profSnap.connectionState == ConnectionState.waiting) {
              return const _Splash();
            }
            if (profSnap.hasError) {
              return _AccessDenied(
                message: 'Could not load your account. Check your connection and try again.',
                email: user.email,
              );
            }
            final profile = profSnap.data;
            if (profile == null || !profile.active) {
              return _AccessDenied(
                message: 'Your account has no active access to this group. '
                    'Ask the organizer to set you up.',
                email: user.email,
              );
            }
            return DashboardShell(profile: profile);
          },
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _AccessDenied extends StatefulWidget {
  final String message;
  final String? email;
  const _AccessDenied({required this.message, this.email});

  @override
  State<_AccessDenied> createState() => _AccessDeniedState();
}

class _AccessDeniedState extends State<_AccessDenied> {
  String? _probeResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Access denied',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(widget.message),
                  if (widget.email != null) ...[
                    const SizedBox(height: 8),
                    Text('Signed in as ${widget.email}',
                        style: const TextStyle(color: Colors.black54)),
                  ],
                  const SizedBox(height: 16),
                  // DEV ONLY (remove in Stage 4): proves the rules block this user.
                  OutlinedButton(
                    onPressed: () async {
                      final r = await probeMembersRead();
                      if (mounted) setState(() => _probeResult = r);
                    },
                    child: const Text('Dev: try reading members'),
                  ),
                  if (_probeResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_probeResult!,
                          style: TextStyle(
                            color: _probeResult!.startsWith('DENIED') ? Brand.ok : Brand.bad,
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: authService.signOut,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}