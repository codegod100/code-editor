# Cloud Code Editor

An initial Flutter desktop editor: browse a local folder, open UTF-8 text files, edit, and save with Ctrl/Cmd+S. It warns before replacing unsaved edits.

## Run

Install the Flutter SDK and enable your desktop platform. From this directory:

```sh
flutter create --platforms=linux,macos,windows .
flutter pub get
flutter run -d linux --target lib/main_desktop.dart  # or macos / windows
```

The generated platform folders are intentionally omitted. No third-party packages are required.

## Next step

Extract file operations behind a workspace interface, then add a remote implementation (for example SSH/SFTP) and a connection screen. The current version edits local files only; it has no cloud connection yet.

## Web target

The default entry point opens a local text file and downloads edits under the same name. Browsers do not grant direct access to arbitrary folders or overwrite the original file. Cloud storage is not connected yet.

```sh
flutter create --platforms=web .
flutter build web
python3 -m http.server 8080 --directory build/web
```

Then open http://localhost:8080. The supplied `web/index.html` is already sufficient for a normal Flutter web build; `flutter create` generates any other standard project metadata.
