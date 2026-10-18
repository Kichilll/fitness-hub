import 'package:cloud_firestore/cloud_firestore.dart';

/// DEV ONLY: tries to read one member so you can see what the
/// security rules allow. Delete this file in Stage 4.
Future<String> probeMembersRead() async {
  try {
    final snap =
        await FirebaseFirestore.instance.collection('members').limit(1).get();
    return 'ALLOWED: read worked (${snap.docs.length} doc found)';
  } on FirebaseException catch (e) {
    return 'DENIED: ${e.code}';
  } catch (e) {
    return 'ERROR: $e';
  }
}