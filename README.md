# Arch Linux packages

Some packages for Arch Linux. Some are new own once others are from AUR adjusted.

For add/adjust packages use `namcap` and `pactree` to check sanity.

* `namcap PKGBUILD`
* `namcap <ready_compiled.pkg.tar.xz>`

* `pactree` `pactree -r`

* `updpkgsums` update pkg cchecksum
* `mksrcinfo` generate *.SRCINFO* file

* `git rev-parse --verify --short HEAD` Get git shortened hash
* `git rev-parse --verify HEAD` Get git last commit

* `diff -Naur before/ after/ > diff.patch`

* COMPILE
    $ makepkg -c -C --force --install

	* if needed add: --skippgpcheck     Do not verify source files with PGP signatures
	* if needed add: --nocheck          Do not run the check() function in the PKGBUILD

---

`process_arch_pkgs.jl` an unfinished script to remove/build/install Arch Linux local packages
