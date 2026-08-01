import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_time.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final time = AppTime.init();

  // Firebase の設定が済んでいなくてもアプリを起動できるようにする。
  //
  // M1 で最初にやりたいのは「Mi Fitness が Health Connect に何を書いているか」の確認で、
  // それに Firebase は要らない。ここで落とすと、Firebase プロジェクトを作るまで
  // 一番知りたいことが確かめられなくなる。
  var firebaseReady = false;
  Object? firebaseError;
  try {
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (e) {
    firebaseError = e;
    debugPrint('Firebase が未設定のためローカルモードで起動します: $e');
  }

  runApp(HealthToolApp(
    time: time,
    firebaseReady: firebaseReady,
    firebaseError: firebaseError,
  ));
}
