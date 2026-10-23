{
  description = "Cine Video Player Standalone FHS AppImage Build Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # 1. Bundled Python environment with runtime modules
      pythonEnv = pkgs.python3.withPackages (ps: with ps; [
        pygobject3
        mpv
      ]);

      # Raw unwrapped Python package (direct binary, bypassing makeCWrapper)
      rawPython = pythonEnv.passthru.python;

      # 2. Native Cine application package definition
      cinePkg = pkgs.python3Packages.buildPythonApplication (finalAttrs: {
        pname = "cine";
        version = "1.8.6";
        pyproject = false;

        src = pkgs.fetchFromGitHub {
          owner = "diegopvlk";
          repo = "Cine";
          tag = "v${finalAttrs.version}";
          hash = "sha256-wtHrKrDpjMVOP1XZ4q+KQ5UBPRq/MNxyKTKuJpryU6o=";
          fetchSubmodules = true;
        };

        dontWrapGApps = true;

        nativeBuildInputs = with pkgs; [
          meson
          ninja
          cmake
          pkg-config
          gettext # Required: provides msgfmt to compile .mo translation files
          wrapGAppsHook4
          blueprint-compiler
          desktop-file-utils
          appstream
        ];

        buildInputs = with pkgs; [
          glib
          gtk4
          libadwaita
          graphene
        ];

        dependencies = with pkgs.python3Packages; [
          pygobject3
          mpv
        ];

        meta = with pkgs.lib; {
          description = "Video Player for Linux";
          homepage = "https://github.com/diegopvlk/Cine";
          license = licenses.gpl3Plus;
          mainProgram = "cine";
          platforms = platforms.linux;
        };
      });

      # 3. Upstream Type 2 AppImage runtime and packaging tool
      appimageRuntime = pkgs.fetchurl {
        url = "https://github.com/AppImage/type2-runtime/releases/latest/download/runtime-x86_64";
        hash = "sha256-YXqncxTVfIuOT66cPws1r3sw1VKctp6Y9k+SUQ7ZikY=";
      };

      appimagetool = pkgs.fetchurl {
        url = "https://github.com/AppImage/appimagetool/releases/latest/download/appimagetool-x86_64.AppImage";
        hash = "sha256-lcvnzOlxf86QxITjQFLufH8ddjWzPBJSW0d2gmp9KbY=";
      };

      # 4. AppDir sanitization and ELF patching script
      patchAppDirPy = pkgs.writeText "patch-appdir.py" ''
        import os, glob, re, subprocess

        # (a) Strip absolute /nix/store paths from .typelib files
        pattern = re.compile(rb"(/nix/store/[^\x00]+)")
        for path in glob.glob("AppDir/usr/lib/girepository-1.0/*.typelib"):
            with open(path, "rb") as f:
                data = f.read()
            new_data = pattern.sub(lambda m: b",".join(p.split(b"/")[-1] for p in m.group(0).split(b",")).ljust(len(m.group(0)), b"\x00"), data)
            if new_data != data:
                with open(path, "wb") as f:
                    f.write(new_data)

        # (b) Scan and patch all ELF binaries across AppDir
        common_rpath = "$ORIGIN:$ORIGIN/..:$ORIGIN/pulseaudio:$ORIGIN/../lib:$ORIGIN/../../..:$ORIGIN/../../../..:$ORIGIN/../../../../lib"
        for root_dir in ["AppDir/usr"]:
            for dirpath, _, filenames in os.walk(root_dir):
                for fname in filenames:
                    # Never run patchelf on the dynamic linker itself
                    if fname.startswith("ld-linux") or fname.startswith("ld-2."):
                        continue
                    fpath = os.path.join(dirpath, fname)
                    if os.path.islink(fpath) or not os.path.isfile(fpath):
                        continue
                    try:
                        with open(fpath, "rb") as f:
                            if f.read(4) != b"\x7fELF": continue
                    except Exception:
                        continue

                    cmd = ["patchelf", "--set-rpath", common_rpath]

                    res = subprocess.run(["patchelf", "--print-needed", fpath], capture_output=True, text=True)
                    if res.returncode == 0:
                        for line in res.stdout.splitlines():
                            line = line.strip()
                            if line.startswith("/nix/store/"):
                                cmd.extend(["--replace-needed", line, os.path.basename(line)])

                    cmd.append(fpath)
                    subprocess.run(cmd, stderr=subprocess.DEVNULL)
      '';

      # 5. Standalone native FHS AppImage derivation
      appimage = pkgs.stdenvNoCC.mkDerivation {
        pname = "cine-appimage";
        version = cinePkg.version;

        nativeBuildInputs = with pkgs; [
          patchelf
          file
          zsync
          glib.dev
          gdk-pixbuf
          pythonEnv
        ];

        # Omitted pkgs.glibcLocales to save 230+ MB
        closureInfo = pkgs.closureInfo {
          rootPaths = [
            cinePkg
            pythonEnv
            rawPython
            pkgs.glibc
            pkgs.gtk4.out
            pkgs.libadwaita.out
            pkgs.graphene.out
            pkgs.pango.out
            pkgs.gdk-pixbuf.out
            pkgs.cairo.out
            pkgs.freetype.out
            pkgs.fontconfig.out
            pkgs.harfbuzz.out
            pkgs.fribidi.out
            pkgs.librsvg.out
            pkgs.mpv.out
            pkgs.mesa.out
            pkgs.libdrm.out
            pkgs.libva.out
            pkgs.libglvnd.out
            pkgs.pulseaudio.out
            pkgs.shared-mime-info
            pkgs.gsettings-desktop-schemas
            pkgs.gobject-introspection
          ];
        };

        dontUnpack = true;
        dontPatchELF = true;
        dontStrip = true;

        installPhase = ''
          runHook preInstall

          mkdir -p AppDir/usr/{bin,lib,share/locale,lib/girepository-1.0}

          # 1. Copy application assets and translations
          cp -rL --no-preserve=mode "${cinePkg}/share/"* AppDir/usr/share/
          [ -d "${cinePkg}/lib" ] && cp -rL --no-preserve=mode "${cinePkg}/lib/"* AppDir/usr/lib/

          for p in "${pkgs.gtk4}" "${pkgs.libadwaita}"; do
            [ -d "$p/share/locale" ] && cp -rL --no-preserve=mode "$p/share/locale/"* AppDir/usr/share/locale/
          done

          # Setup symlinks for Chinese locale naming compatibility
          [ -d AppDir/usr/share/locale/zh_Hans ] && [ ! -d AppDir/usr/share/locale/zh_CN ] && ln -sf zh_Hans AppDir/usr/share/locale/zh_CN
          [ -d AppDir/usr/share/locale/zh_CN ] && [ ! -d AppDir/usr/share/locale/zh_Hans ] && ln -sf zh_CN AppDir/usr/share/locale/zh_Hans

          # Bundle matching glibc runtime and the ld-linux dynamic linker
          cp -fL --no-preserve=mode ${pkgs.glibc}/lib/*.so* AppDir/usr/lib/ 2>/dev/null || true
          if [ -d "${pkgs.glibc}/lib/gconv" ]; then
            cp -rL --no-preserve=mode "${pkgs.glibc}/lib/gconv" AppDir/usr/lib/ 2>/dev/null || true
          fi

          # Copy the unwrapped raw Python binary
          REAL_PY=$(readlink -f "${rawPython}/bin/python3")
          cp -L --no-preserve=mode "$REAL_PY" AppDir/usr/bin/python3
          chmod +x AppDir/usr/bin/python3

          cp -rL --no-preserve=mode "${pythonEnv}/lib/"* AppDir/usr/lib/ 2>/dev/null || true
          if [ -d "${rawPython}/lib" ]; then
            cp -rL --no-preserve=mode "${rawPython}/lib/"* AppDir/usr/lib/ 2>/dev/null || true
          fi

          find AppDir/usr/lib -type d \( -name "test" -o -name "tests" -o -name "idlelib" -o -name "__pycache__" \) -exec rm -rf {} + 2>/dev/null || true
          find AppDir/usr/lib -type f -name "*.pyc" -delete 2>/dev/null || true

          # 2. Extract shared libraries and typelibs from the closure
          while IFS= read -r storePath; do
            case "$storePath" in
              *linux-headers*|*llvm*|*intel-media-driver*|*-dev) continue ;;
              *)
                if [ -d "$storePath/lib" ]; then
                  find -L "$storePath/lib" -maxdepth 2 -type f \( -name "*.so" -o -name "*.so.*" \) ! -path "*/dri/*" -exec cp -f --no-preserve=mode -t AppDir/usr/lib/ {} + 2>/dev/null || true
                fi
                if [ -d "$storePath/lib/pulseaudio" ]; then
                  mkdir -p AppDir/usr/lib/pulseaudio
                  find -L "$storePath/lib/pulseaudio" -type f \( -name "*.so" -o -name "*.so.*" \) -exec cp -f --no-preserve=mode -t AppDir/usr/lib/pulseaudio/ {} + 2>/dev/null || true
                fi
                find "$storePath" -type f -name "*.typelib" -exec cp -f --no-preserve=mode -t AppDir/usr/lib/girepository-1.0/ {} + 2>/dev/null || true
                if [ -d "$storePath/lib/gdk-pixbuf-2.0" ]; then
                  mkdir -p AppDir/usr/lib/gdk-pixbuf-2.0
                  cp -rL --no-preserve=mode "$storePath/lib/gdk-pixbuf-2.0/"* AppDir/usr/lib/gdk-pixbuf-2.0/ 2>/dev/null || true
                fi
                ;;
            esac
          done < "$closureInfo/store-paths"

          # Create missing short and major version symlinks
          for sofile in AppDir/usr/lib/*.so.*; do
            [ -f "$sofile" ] || continue
            base="$(basename "$sofile")"
            short_so="''${base%%.so*}.so"
            major_so="$(echo "$base" | sed -E 's/(\.so\.[0-9]+).*/\1/')"
            [ ! -e "AppDir/usr/lib/$short_so" ] && ln -sf "$base" "AppDir/usr/lib/$short_so" 2>/dev/null || true
            [ ! -e "AppDir/usr/lib/$major_so" ] && ln -sf "$base" "AppDir/usr/lib/$major_so" 2>/dev/null || true
          done

          # 3. Run full ELF sanitization and patching
          python3 ${patchAppDirPy}
          find AppDir/usr/lib -type f -name "mpv.py" -exec sed -i -E 's|"/nix/store/[^"]+/libmpv\.so"|"libmpv.so"|g' {} + 2>/dev/null || true

          # 4. Configure GDK-Pixbuf loaders and cache
          PIXBUF_LOADERS_DIR=$(find AppDir/usr/lib/gdk-pixbuf-2.0 -type d -name "loaders" 2>/dev/null | head -n 1 || true)
          if [ -n "$PIXBUF_LOADERS_DIR" ]; then
            mkdir -p AppDir/usr/lib/gdk-pixbuf-2.0/2.10.0
            gdk-pixbuf-query-loaders $(find "$PIXBUF_LOADERS_DIR" -name "*.so") > AppDir/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache 2>/dev/null || true
            sed -i "s|$PWD/AppDir/usr/|../|g" AppDir/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache 2>/dev/null || true
          fi

          # 5. Consolidate and compile GSettings schemas
          mkdir -p AppDir/usr/share/glib-2.0/schemas
          find "${cinePkg}" -name "*.gschema.xml" -exec cp -t AppDir/usr/share/glib-2.0/schemas/ {} + 2>/dev/null || true
          for pkg in "${pkgs.gtk4}" "${pkgs.libadwaita}" "${pkgs.gsettings-desktop-schemas}"; do
            [ -d "$pkg/share/glib-2.0/schemas" ] && cp -d "$pkg"/share/glib-2.0/schemas/*.xml AppDir/usr/share/glib-2.0/schemas/ 2>/dev/null || true
          done
          chmod -R u+w AppDir/usr/share/glib-2.0/schemas
          glib-compile-schemas AppDir/usr/share/glib-2.0/schemas

          # 6. Set up desktop entry and application icon symlinks
          DESKTOP_FILE=$(find AppDir/usr/share/applications -name "*.desktop" | head -n 1)
          ln -sf "usr/share/applications/$(basename "$DESKTOP_FILE")" AppDir/
          ICON_NAME=$(grep -m1 '^Icon=' "$DESKTOP_FILE" | cut -d= -f2)
          ICON_FILE=$(find AppDir/usr/share/icons \( -name "$ICON_NAME.*" -o -iname "*cine*.svg" \) | head -n 1)
          if [ -n "$ICON_FILE" ]; then
            ln -sf "''${ICON_FILE#AppDir/}" "AppDir/$ICON_NAME.''${ICON_FILE##*.}"
            ln -sf "''${ICON_FILE#AppDir/}" AppDir/.DirIcon
          fi

          # 7. Generate entry script (pure Python script invoked via bundled ld-linux)
          cat << 'EOF' > AppDir/usr/bin/cine-entry
import sys, os, glob, ctypes, locale, gettext

appdir = os.environ.get("APPDIR", "")
usr_lib = os.path.join(appdir, "usr", "lib")
share_dir = os.path.join(appdir, "usr", "share")
cine_share = os.path.join(share_dir, "cine")
localedir = os.path.join(share_dir, "locale")

# 1. Initialize and bind C runtime & Python i18n domains
try:
    locale.setlocale(locale.LC_ALL, "")
except Exception:
    pass

try:
    libc = ctypes.CDLL(os.path.join(usr_lib, "libc.so.6"))
    for domain in [b"cine", b"com.github.diegopvlk.Cine", b"gtk40", b"libadwaita"]:
        libc.bindtextdomain(domain, localedir.encode("utf-8"))
        libc.bind_textdomain_codeset(domain, b"UTF-8")
    libc.textdomain(b"cine")
except Exception:
    pass

for domain in ["cine", "com.github.diegopvlk.Cine", "gtk40", "libadwaita"]:
    gettext.bindtextdomain(domain, localedir)
gettext.textdomain("cine")

# 2. Preload low-level rendering and font libraries
for lib in ["libgbm.so.1", "libfreetype.so.6", "libharfbuzz.so.0", "libfontconfig.so.1"]:
    lp = os.path.join(usr_lib, lib)
    if os.path.exists(lp):
        try: ctypes.CDLL(lp, mode=ctypes.RTLD_GLOBAL)
        except Exception: pass

if os.path.isdir(cine_share):
    sys.path.insert(0, cine_share)

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gio, Gtk, Adw

for res in glob.glob(os.path.join(share_dir, "**", "*.gresource"), recursive=True):
    try: Gio.Resource.load(res)._register()
    except Exception: pass

Adw.init()

from cine import main
sys.exit(main.main("${cinePkg.version}"))
EOF
          chmod +x AppDir/usr/bin/cine-entry

          # 8. Generate AppRun entry point (Plan B: dynamic host locale detection)
          cat << 'EOF' > AppDir/AppRun
#!/usr/bin/env bash
set -e

export APPDIR="''${APPDIR:-$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")}"
export PATH="$APPDIR/usr/bin:$PATH"
export PYTHONNOUSERSITE=true

# Plan B: Try host locale-archive first, otherwise fall back to host locale directories
if [ -z "$LOCALE_ARCHIVE" ]; then
  if [ -f "/usr/lib/locale/locale-archive" ]; then
    export LOCALE_ARCHIVE="/usr/lib/locale/locale-archive"
  elif [ -f "/run/current-system/sw/lib/locale/locale-archive" ]; then
    export LOCALE_ARCHIVE="/run/current-system/sw/lib/locale/locale-archive"
  fi
fi

# Fallback for systems with individual locale directories (e.g., Debian/Ubuntu)
if [ -d "/usr/lib/locale" ]; then
  export LOCPATH="/usr/lib/locale''${LOCPATH:+:$LOCPATH}"
fi

[ -d "$APPDIR/usr/lib/gconv" ] && export GCONV_PATH="$APPDIR/usr/lib/gconv"

if [ -n "$LANG" ]; then
  case "$LANG" in
    zh_CN*) export LANGUAGE="zh_CN:zh_Hans:zh''${LANGUAGE:+:$LANGUAGE}" ;;
    zh_TW*|zh_HK*) export LANGUAGE="zh_TW:zh_Hant:zh''${LANGUAGE:+:$LANGUAGE}" ;;
  esac
fi

export TEXTDOMAIN="cine"
export TEXTDOMAINDIR="$APPDIR/usr/share/locale"
export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$APPDIR/usr/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# Host GPU driver pass-through
HOST_DRI="/run/opengl-driver/lib/dri:/usr/lib64/dri:/usr/lib/x86_64-linux-gnu/dri:/usr/lib/dri"
export LIBVA_DRIVERS_PATH="$HOST_DRI''${LIBVA_DRIVERS_PATH:+:$LIBVA_DRIVERS_PATH}"
export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d:/usr/share/glvnd/egl_vendor.d:$APPDIR/usr/share/glvnd/egl_vendor.d"

[ -d "/etc/fonts" ] && export FONTCONFIG_PATH="/etc/fonts''${FONTCONFIG_PATH:+:$FONTCONFIG_PATH}"
[ -f "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" ] && export GDK_PIXBUF_MODULE_FILE="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"

export PYTHONPATH="$APPDIR/usr/share/cine:$APPDIR/usr/lib/${rawPython.libPrefix}/site-packages''${PYTHONPATH:+:$PYTHONPATH}"
export GI_TYPELIB_PATH="$APPDIR/usr/lib/girepository-1.0"
export MPV_OPTS="--hwdec=auto-safe --vo=gpu ''${MPV_OPTS:-}"

LOADER="$APPDIR/usr/lib/ld-linux-x86-64.so.2"
LIB_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/pulseaudio:/run/opengl-driver/lib:/usr/lib64/dri:/usr/lib/x86_64-linux-gnu/dri:/usr/lib/dri"

# Execute python3 using the bundled dynamic linker to fully decouple from the host glibc
exec "$LOADER" --library-path "$LIB_PATH" "$APPDIR/usr/bin/python3" "$APPDIR/usr/bin/cine-entry" "$@"
EOF

          # Set proper read, write, and execute permissions across AppDir
          chmod -R u+w AppDir
          chmod +x AppDir/AppRun AppDir/usr/bin/* AppDir/usr/lib/ld-linux-x86-64.so.2
          chmod -R a+rX AppDir

          # 9. Assemble and package final AppImage
          install -m755 ${appimagetool} ./appimagetool

          mkdir -p "$out"
          FINAL_APPIMAGE="$out/Cine-${cinePkg.version}-x86_64.AppImage"

          ARCH=x86_64 ./appimagetool --appimage-extract-and-run \
            --runtime-file "${appimageRuntime}" \
            -u "gh-releases-zsync|diegopvlk|Cine|latest|*x86_64.AppImage.zsync" \
            AppDir "$FINAL_APPIMAGE"

          cd "$out"
          zsyncmake -u "$(basename "$FINAL_APPIMAGE")" "$FINAL_APPIMAGE"

          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Standalone native FHS AppImage of Cine Video Player";
          homepage = "https://github.com/diegopvlk/Cine";
          license = licenses.gpl3Plus;
          platforms = [ "x86_64-linux" ];
        };
      };
    in
    {
      packages.${system} = {
        default = appimage;
        inherit appimage cinePkg;
      };
    };
}
