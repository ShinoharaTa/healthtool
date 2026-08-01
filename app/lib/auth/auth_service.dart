import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// サインインに失敗した理由を、ユーザーに出せる日本語で持ち回る。
class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'AuthFailure: $message${cause == null ? '' : ' ($cause)'}';
}

/// Firebase Auth と Google サインインの組み合わせ。
///
/// google_sign_in 7.x は認証 (誰か) と認可 (何にアクセスしてよいか) を分離した。
/// Firebase の資格情報に必要なのは ID トークンだけなので、
/// スコープの認可は要求せず authenticate() だけを使う。
class AuthService {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  bool _googleInitialized = false;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  /// Google サインインの初期化。
  ///
  /// Android では serverClientId に Firebase の Web クライアント ID を渡す必要がある。
  /// これを渡さないと ID トークンが返らず、Firebase 側で資格情報を作れない。
  /// 値は google-services.json の oauth_client のうち client_type=3 のもの。
  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: _serverClientId);
    _googleInitialized = true;
  }

  /// `flutterfire configure` 後に --dart-define で渡す。
  /// 未設定でも Android では google-services.json から解決されることがあるため、
  /// 空文字なら null にして委ねる。
  static String? get _serverClientId {
    const v = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
    return v.isEmpty ? null : v;
  }

  Future<User> signInWithGoogle() async {
    try {
      await _ensureGoogleInitialized();

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        throw const AuthFailure('この環境では Google サインインを利用できません');
      }

      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthFailure(
          'Google から ID トークンを取得できませんでした',
          cause: 'serverClientId が未設定か、SHA-1 証明書フィンガープリントが Firebase に登録されていない可能性があります',
        );
      }

      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final result = await _auth.signInWithCredential(credential);
      final user = result.user;
      if (user == null) throw const AuthFailure('サインインに失敗しました');
      return user;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthFailure('サインインをキャンセルしました');
      }
      throw AuthFailure('Google サインインに失敗しました', cause: e);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure('Firebase の認証に失敗しました', cause: e.message ?? e.code);
    } catch (e) {
      if (e is AuthFailure) rethrow;
      debugPrint('予期しないサインインエラー: $e');
      throw AuthFailure('サインインに失敗しました', cause: e);
    }
  }

  Future<void> signOut() async {
    // Google 側もサインアウトしないと、次回にアカウント選択画面が出ず
    // 別アカウントへの切り替えができなくなる。
    if (_googleInitialized) {
      await GoogleSignIn.instance.signOut();
    }
    await _auth.signOut();
  }
}
