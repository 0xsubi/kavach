package com.kavach.desktop_mobile

import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth's biometric prompt needs a FragmentActivity, not the plain
// FlutterActivity that `flutter create` scaffolds by default.
class MainActivity : FlutterFragmentActivity()
