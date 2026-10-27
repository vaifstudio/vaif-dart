/// Where a client keeps the signed-in session between launches.
library;

/// Saves the signed-in session between launches of an app.
///
/// Pass an implementation to `VaifClient(sessionStorage: ...)`. The client
/// then saves every sign-in and token refresh, deletes the saved session on
/// sign-out, and restores it with `auth.loadSession()`. Implement it over
/// your platform's secure storage, such as the iOS Keychain or the Android
/// Keystore (for example with `flutter_secure_storage`): the saved value
/// contains the refresh token, which signs the user in.
///
/// The client chooses the key (`auth.sessionStorageKey`), from the API base
/// URL and the project ID, so clients for different projects, or for one
/// project at different base URLs, never restore each other's session. The
/// client calls one method at a time and waits for it to finish, in the
/// order the calls were made.
///
/// A method that cannot complete its work must throw. A failure to save a
/// new session makes the client delete the saved one, so an older session
/// is not restored in its place; if that delete fails too, the sign-in call
/// throws `VaifSessionStorageException`.
abstract interface class SessionStorage {
  /// The value saved under [key], or null when nothing is saved.
  Future<String?> read(String key);

  /// Saves [value] under [key], replacing any value saved before.
  Future<void> write(String key, String value);

  /// Removes the value saved under [key]. Succeeds when nothing is saved.
  Future<void> delete(String key);
}
