import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum StaffRole { organizer, treasurer }

class StaffProfile {
  final String uid;
  final String displayName;
  final StaffRole role;
  final bool active;

  const StaffProfile({
    required this.uid,
    required this.displayName,
    required this.role,
    required this.active,
  });

  bool get isTreasurer => role == StaffRole.treasurer;
  String get roleLabel => role == StaffRole.treasurer ? 'Treasurer' : 'Organizer';
}

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Who is signed in (null = nobody).
  Stream<User?> get authChanges => _auth.authStateChanges();

  /// The role document for this user. Null means "no valid role assigned".
  Stream<StaffProfile?> profileStream(String uid) {
    return _db.collection('users').doc(uid).snapshots().map((snap) {
      if (!snap.exists) return null;
      final data = snap.data()!;
      final role = switch (data['role']) {
        'organizer' => StaffRole.organizer,
        'treasurer' => StaffRole.treasurer,
        _ => null,
      };
      if (role == null) return null;
      return StaffProfile(
        uid: uid,
        displayName: (data['displayName'] as String?) ?? 'Staff',
        role: role,
        active: data['active'] == true,
      );
    });
  }

  Future<void> signIn(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email.trim(), password: password);

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() => _auth.signOut();
}

final authService = AuthService();