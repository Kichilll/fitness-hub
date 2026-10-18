import 'package:flutter/material.dart';

import '../dev/rules_probe.dart';
import '../services/auth_service.dart';
import '../theme.dart';

/// Stage 1 placeholder. Replaced in Stage 4 by the real sidebar + dashboard.
class DashboardShell extends StatefulWidget {
  final StaffProfile profile;
  const DashboardShell({super.key, required this.profile});

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  String? _probeResult;

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Brand.navy,
        foregroundColor: Colors.white,
        title: const Text('Fitness Hub'),
        actions: [
          TextButton(
            onPressed: authService.signOut,
            child: const Text('Sign out', style: TextStyle(color: Brand.mint)),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Welcome, ${p.displayName}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Role: ${p.roleLabel}'),
                  const SizedBox(height: 16),
                  const Text('Stage 1 check: the rules should ALLOW staff to read members.'),
                  const SizedBox(height: 8),
                  // DEV ONLY (remove in Stage 4)
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
                            color: _probeResult!.startsWith('ALLOWED') ? Brand.ok : Brand.bad,
                            fontWeight: FontWeight.w600,
                          )),
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