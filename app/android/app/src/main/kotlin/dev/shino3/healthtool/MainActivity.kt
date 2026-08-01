package dev.shino3.healthtool

import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * FlutterActivity ではなく FlutterFragmentActivity を継承する必要がある。
 *
 * health パッケージは Health Connect の権限リクエストに AndroidX の
 * ActivityResultContract を使う。その登録には FragmentActivity が必要で、
 * FlutterActivity のままだと権限ダイアログが出ないまま失敗する。
 */
class MainActivity : FlutterFragmentActivity()
