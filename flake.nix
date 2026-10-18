{
  description = "Cine Video Player Standalone AppImage Build Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
      };

      # 1. Native Cine package derivation
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
          wrapGAppsHook4
          blueprint-compiler
          desktop-file-utils
          appstream
        ];

        buildInputs = with pkgs; [
          gettext
          glib
          gtk4
          libadwaita
        ];

        dependencies = with pkgs.python3Packages; [
          pygobject3
          mpv
        ];

        preFixup = ''
          makeWrapperArgs+=("''${gappsWrapperArgs[@]}")
          makeWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libGL ]})
        '';

        meta = {
          description = "Video Player for Linux";
          homepage = "https://github.com/diegopvlk/Cine";
          license = pkgs.lib.licenses.gpl3Plus;
          maintainers = with pkgs.lib.maintainers; [ ];
          mainProgram = "cine";
          platforms = pkgs.lib.platforms.linux;
        };
      });

      # 2. Upstream Type 2 AppImage runtime binary
      appimageRuntime = pkgs.fetchurl {
        url = "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64";
        hash = "sha256-FW9L296cUtAYFGAAE+Cic/ARjcLemJdfPIxjQn7HkHQ=";
      };

      # 3. Static PRoot binary used as a fallback when unprivileged bubblewrap is unavailable
      prootStatic = pkgs.fetchurl {
        url = "https://github.com/proot-me/proot/releases/download/v5.5.0/proot";
        hash = "sha256-2xhTAKnaq7zoasp2MtjH/cQkn28VMXGVQBO3DF9JHsA=";
      };

      # 4. Standalone AppImage construction
      appimage = pkgs.stdenv.mkDerivation {
        name = "Cine-${cinePkg.version}-x86_64.AppImage";

        nativeBuildInputs = with pkgs; [
          squashfsTools
          binutils
          coreutils
          zsync
        ];

        closureInfo = pkgs.closureInfo { rootPaths = [ cinePkg ]; };

        buildCommand = ''
          mkdir -p AppDir/nix/store
          while IFS= read -r path; do
            cp -a "$path" AppDir/nix/store/
          done < "$closureInfo/store-paths"

          chmod -R u+w AppDir/nix/store

          # Safely remove static libraries and strip binaries without following symlinks
          find AppDir/nix/store -type f \( -name "*.a" -o -name "*.la" \) -delete 2>/dev/null || true
          find AppDir/nix/store -type f \( -name "*.so*" -o -perm -0100 \) -exec strip --strip-unneeded {} + 2>/dev/null || true

          # Bundle static bubblewrap and static proot
          cp ${pkgs.pkgsStatic.bubblewrap}/bin/bwrap AppDir/bwrap
          chmod +x AppDir/bwrap
          strip --strip-unneeded AppDir/bwrap 2>/dev/null || true

          cp ${prootStatic} AppDir/proot
          chmod +x AppDir/proot

          # Copy shared assets for desktop integration
          mkdir -p AppDir/usr/share
          if [ -d "${cinePkg}/share" ]; then
            cp -r "${cinePkg}/share/"* AppDir/usr/share/
          fi

          # Symlink desktop file to AppDir root
          DESKTOP_FILE=$(find AppDir/usr/share/applications -name "*.desktop" | head -n 1)
          if [ -n "$DESKTOP_FILE" ]; then
            ln -sf "usr/share/applications/$(basename "$DESKTOP_FILE")" AppDir/
          fi

          # Locate application icon and link it as AppImage icon and .DirIcon
          ICON_FILE=$(find AppDir/usr/share/icons -name "*cine*.svg" -o -name "*cine*.png" | head -n 1)
          if [ -n "$ICON_FILE" ]; then
            ICON_REL_PATH="''${ICON_FILE#AppDir/}"
            ln -sf "$ICON_REL_PATH" AppDir/
            ln -sf "$ICON_REL_PATH" AppDir/.DirIcon
          fi

          # Standard entrypoint symlinks
          mkdir -p AppDir/bin
          ln -s "${cinePkg}/bin/cine" AppDir/bin/cine
          ln -s "${cinePkg}/bin/cine" AppDir/entrypoint

          # Multiplexer script handling bwrap and proot sandboxing
          cat << 'EOF' > AppDir/AppRun
          #!/usr/bin/env bash
          set -e

          # 1. Locate mounted AppDir root
          HERE="''${APPDIR:-$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")}"
          TARGET="$(readlink "$HERE/entrypoint")"
          TARGET="''${TARGET:-${cinePkg}/bin/cine}"

          # 2. Sound server configuration
          if [ -z "$PULSE_SERVER" ]; then
            if [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ]; then
              export PULSE_SERVER="unix:''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
            elif [ -S "/run/user/$(id -u)/pulse/native" ]; then
              export PULSE_SERVER="unix:/run/user/$(id -u)/pulse/native"
            fi
          fi

          # 3. Fast path: Direct execution on native NixOS systems
          if [ -x "$TARGET" ]; then
            exec "$TARGET" "$@"
          fi

          # 4. Collect common host mount points (removable media, system fonts, GPU/DRI drivers)
          COMMON_BINDS=()
          for d in /media /mnt /run/media; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          for d in /usr/share/fonts /usr/local/share/fonts /etc/fonts; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          for d in /run/opengl-driver/lib/dri /usr/lib/x86_64-linux-gnu/dri /usr/lib64/dri /usr/lib/dri; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          # 5. Check if unprivileged bubblewrap is supported
          CAN_BWRAP=0
          if [ -x "$HERE/bwrap" ] && "$HERE/bwrap" --ro-bind / / true >/dev/null 2>&1; then
            CAN_BWRAP=1
          fi

          # 6. Dispatch execution: bubblewrap preferred, fallback to proot
          if [ "$CAN_BWRAP" -eq 1 ]; then
            BWRAP_ARGS=()
            for d in /*; do
              case "$d" in
                /proc|/dev|/sys|/tmp|/run|/var|/nix|/home|/root|/media|/mnt) ;;
                *) [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d") ;;
              esac
            done

            for d in "''${COMMON_BINDS[@]}"; do
              BWRAP_ARGS+=(--bind "$d" "$d")
            done

            exec "$HERE/bwrap" \
              "''${BWRAP_ARGS[@]}" \
              --proc /proc \
              --dev-bind /dev /dev \
              --ro-bind /sys /sys \
              --bind /tmp /tmp \
              --bind /run /run \
              --bind /var /var \
              --bind "$HOME" "$HOME" \
              --dir /nix \
              --ro-bind "$HERE/nix/store" /nix/store \
              -- "$TARGET" "$@"
          elif [ -x "$HERE/proot" ]; then
            PROOT_ARGS=(-r / -b "$HERE/nix/store:/nix/store")

            for d in /dev /proc /sys /tmp /run /var "$HOME"; do
              [ -d "$d" ] && PROOT_ARGS+=(-b "$d:$d")
            done

            for d in "''${COMMON_BINDS[@]}"; do
              PROOT_ARGS+=(-b "$d:$d")
            done

            exec "$HERE/proot" \
              "''${PROOT_ARGS[@]}" \
              "$TARGET" "$@"
          else
            echo "Error: Neither bwrap nor proot is functional on this system." >&2
            exit 1
          fi
          EOF
          chmod +x AppDir/AppRun

          # 7. Create compressed SquashFS filesystem
          mksquashfs AppDir squashfs.img \
            -root-owned -noappend \
            -comp zstd -b 1M -Xcompression-level 22

          # 8. Concatenate runtime header and squashfs payload into AppImage binary
          mkdir -p "$out"
          FINAL_APPIMAGE="$out/Cine-${cinePkg.version}-x86_64.AppImage"
          cat ${appimageRuntime} squashfs.img > "$FINAL_APPIMAGE"
          chmod +x "$FINAL_APPIMAGE"

          # 9. Generate zsync delta file for differential updates
          cd "$out"
          zsyncmake -u "$(basename "$FINAL_APPIMAGE")" "$FINAL_APPIMAGE"
        '';
      };
    in
      {
        packages.${system} = {
          default = appimage;
          inherit appimage cinePkg;
        };
      };
}
