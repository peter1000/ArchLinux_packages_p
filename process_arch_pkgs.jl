#!/usr/bin/env julia

# process_arch_pkgs.jl: Copyright (C) 2015, peter1000 <https://github.com/peter1000>
#
#
# TODO:
#   * maybe do it with proper dependency checks (wrap lipalpm) - for the time being just a fast hack
#   * maybe pre-check if pacman database is locked before removing it.
#


"""
For now it needs helper file: `PKGBUILD_PKG_INFO.sh`

All sub-folders which contain a PKGBUILD file will be processed or one can specify a list of packagedirs:
see option `--dopkg`

## How to run

*  see PKGEXT, INSTALL_PKG_ARCH, PACKMAN_DB_LOCK_PATH and USAGE_TXT

* NOTE: run it in a terminal: otherwise sometimes error: 'ERROR: LoadError: could not spawn `PKGBUILD_PKG_INFO.sh`'

* NOTE: some conflicts can not be automatic installed: if it builded fine use:
  `sudo pacman --force -U  compiled_pkgname_archive_file`
"""

const TIMEFORMAT = "%a %d %b %Y %H:%M:%S"
const PKGEXT = ".pkg.tar.xz"    # e.g. ".pkg.tar.xz"  see also settings for 'PKGEXT' in your installed `makepkg.conf`
const INSTALL_PKG_ARCH = ["x86_64", "any"]   # SKIP the i686
const PACKMAN_DB_LOCK_PATH = "/var/lib/pacman/db.lck"

const USAGE_TXT = """\n\n

    USAGE: julia process_arch_pkgs.jl <sudo_password> <action>  [optionals] [pkg selection]

    `--help`:           display this USAGE TEXT: this overrules any other argument.

    REQUIRED

    `sudo_password`:     must be a correct sudo password which is needed by e.g. `pacman` to install, remove packages

    `action`: must be one of:
        'writepkginfo':     Writes the current pkginfo (name, version etc.) to file `PKGINFO.md`
        `writenamcap`:      Writes the output of 'namcap filearchive` to file `NAMCAP_PKG_OUTPUT.md`.
                            NOTE: This requires that previously pkgs where compiled: e.g. action: `build or install`
                                command: `namcap compiled_pkgname_filearchive`
        `writedeps`:        Writes dependency levels to file `DEPENDENCY_LEVEL.md.
                            Only included info is the one retrieved from the included PKGBUILD files.

        'getsources':       Only download the sources - updates PKGBUILD version for VCS sources. see option: --holdver
                                command: `makepkg --noconfirm --nobuild --nodeps --noprepare`
        'allsourcetar':     Generate pkgbuild tarball including downloaded sources. see option: --holdver
                                command: `makepkg --noconfirm --force --nodeps --allsource` see option: --holdver
        'pkgbuildtar':      Generate pkgbuild tarball without downloaded sources. see option: --holdver
                                command: `makepkg --noconfirm --force --source`
        'build':            Get sources & builds them without installing. see option: --holdver
                                command: `makepkg --noconfirm --force --clean --cleanbuild --log`

                        === ATTENTION: Potentially breaking the Operating system. ===

        'remove':           Removes the pkg without any checks. ATTENTION: Potentially breaking the system.
                                command: `pacman -Rdd pkgname`
        'install':          Downloads first all needed sources - than builds and installs one pkg after another.
                            see also option: --holdver
                            ATTENTION: force install, overwrite conflicting files. Potentially breaking the system.
                                getsource command: `makepkg --noconfirm --nobuild --nodeps --noprepare`
                                build command: `makepkg --noconfirm --force --clean --cleanbuild --holdver --log`
                                install command: `pacman --noconfirm --force -U pkgfile`
                            Note: for the build part - logfiles are written:
                                  see your makepkg.conf `LOGDEST` for the location.

    OPTIONAL

    `--pkginfo file`:   optional writes before running any of the actions. e.g. current pkginfo (name, version) to file
                        This can be a useful information if for instance a git package does not compile with the last
                        checkout

    `--holdver`:        optional: if given it  will hold the version for VCS sources.
                        NOTE: for action `install` this is different than the one permanent given to the build command,
                        this will be passed to the `getsource` part.

    SECLECTION

    `--dopkg pkgdir`:   optional with relative or absolute path to package folders: if set only these packages are
                        processed. ` --dopkg pkgdir1 pkgdir2 pkgdir3`

   ** EXAMPLES**


    # TO REMOVE PACKAGES in all subfolders

    `\$ julia process_arch_pkgs.jl MySudoPassword remove`

    # TO REMOVE SELECTED PACKAGES

    `\$ julia process_arch_pkgs.jl MySudoPassword remove --dopkg mypackage1 /home/test/mypackage2

    # TO DOWNLOAD PACKAGE SOURCES and write a `pkginfo file`

    `\$ julia process_arch_pkgs.jl MySudoPassword getsource --pkginfo PKGINFO.md`

    # TO DOWNLOAD PACKAGE SOURCES and write a `namcap file`

    `\$ julia process_arch_pkgs.jl MySudoPassword writenamcap`

    # TO WRITE A DEPENDENCY TREE FILE

    `\$ julia process_arch_pkgs.jl MySudoPassword writedeps`

    # TO INSTALL and hold the version

    `\$ julia process_arch_pkgs.jl MySudoPassword install --holdver`
"""


"""
Removes arch version from items like 'provides', depends'
"""
function clean_version(item)
    version_sep = (">=", "<=", ">", "<", "=") # important "=" is last
    no_version = item
    for sep in version_sep
        if contains(item, sep)
            no_version = split(item, sep)[1]
            break
        end
    end
    return no_version
end


"""
Simple user prompt
"""
function input(prompt::AbstractString="")
    print(prompt)
    chomp(readline())
end


"""
Returns a sorted vector with only unique valid package dirs.

Validation is done if the absolute dir contains a file: `PKGBUILD`
"""
function validate_pkglist(do_pkg::Vector)
    valid_pkglist = Vector{UTF8String}()
    for pkg in do_pkg
        absdir = abspath(pkg)
        if isfile(joinpath(absdir, "PKGBUILD"))
            pkgdir = basename(absdir)
            pkgdir in valid_pkglist                                                              ?
                throw(ArgumentError("\n\npkgdir: <$(pkgdir)> has been already added once.\n\n")) :
                push!(valid_pkglist, pkgdir)
        end
    end
    return sort(valid_pkglist)
end


"""
For each entry in `pkgdirlist` retrieve some info from it's 'PKGBUILD'.

'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function get_pkginfo(pkgdirlist::Vector{UTF8String})
    pkginfo = Dict()
    for pkg in pkgdirlist
        pkgbase, epoch, pkgver, pkgrel, pkgnames, pkgdeps, pkgprovides = extract_pkginfo(pkg)
        pkginfo[pkg] = Dict{Any,Any}("absdir"  => abspath(pkg), "pkgbase"     => pkgbase, "epoch"    => epoch,
                                     "pkgver"  => pkgver      , "pkgrel"      => pkgrel , "pkgnames" => pkgnames,
                                     "pkgdeps" => pkgdeps     , "pkgprovides" => pkgprovides)
    end
    return pkginfo
end


"""
READS a `PKGBUILD` file and extracts some infos.

IMPORTANT:

  * All deps: depends, makedepends, checkdepends, optdepends plus any 'x86_64' architecture-specific once.
  * All provides: pkgbase, provides plus any additional 'x86_64' architecture-specific once.
"""
function extract_pkginfo(pkg::AbstractString)
    PKGBUILD_path = joinpath(abspath(pkg), "PKGBUILD")
    pkgver = -1
    pkgrel = -1
    epoch = -1
    pkgnames = Set()

    # All deps: depends, makedepends, checkdepends, optdepends plus any 'x86_64' architecture-specific once.
    pkgdeps = Set()
    # All provides: pkgbase, provides plus any additional 'x86_64' architecture-specific once.
    pkgprovides = Set()

    PKGBUILD_content = readall(`bash PKGBUILD_PKG_INFO.sh $PKGBUILD_path`)
    lines = split(PKGBUILD_content, '\n')

    # base name is in the first line
    line_1 = lines[1]
    pkgbase = startswith(line_1, "pkgbase = ") ?
        line_1[11:end]                         :
        throw(ArgumentError("\n\npkg: <$(pkg)> Could not extract any 'pkgbase'.\n\n$(PKGBUILD_content)"))

    # Extract package `epoch, pkgver, pkgrel`
    found_epoch = false
    found_pkgver = false
    found_pkgrel = false
    for line in lines
        if startswith(line, "	epoch = ")
            found_epoch && throw(ArgumentError("\n\npkg: <$(pkg)> Seems we found a second <found_epoch>"))
            epoch = line[10:end]
            found_epoch = true
        elseif startswith(line, "	pkgver = ")
            found_pkgver && throw(ArgumentError("\n\npkg: <$(pkg)> Seems we found a second <pkgver>"))
            pkgver = line[11:end]
            found_pkgver = true
        elseif startswith(line, "	pkgrel = ")
            found_pkgrel && throw(ArgumentError("\n\npkg: <$(pkg)> Seems we found a second <pkgver>"))
            pkgrel = line[11:end]
            found_pkgrel = true
        elseif startswith(line, "pkgname")
            pkgname = line[11:end]
            push!(pkgnames, pkgname)

        # All deps: depends, makedepends, checkdepends, optdepends plus any 'x86_64' architecture-specific once.
        elseif startswith(line, "	depends = ")
            dep = line[12:end]
            push!(pkgdeps, clean_version(dep))
        elseif startswith(line, "	depends_x86_64 = ")
            dep = line[19:end]
            push!(pkgdeps, clean_version(dep))
        elseif startswith(line, "	makedepends = ")
            dep = line[16:end]
            push!(pkgdeps, clean_version(dep))
        elseif startswith(line, "	makedepends_x86_64 = ")
            dep = line[23:end]
            push!(pkgdeps, clean_version(dep))
        elseif startswith(line, "	checkdepends = ")
            dep = line[17:end]
            push!(pkgdeps, clean_version(dep))
        elseif startswith(line, "	checkdepends_x86_64 = ")
            dep = line[24:end]
            push!(pkgdeps, clean_version(dep))
        elseif startswith(line, "	optdepends = ")
            dep = line[15:end]
            push!(pkgdeps, clean_version(dep))
        elseif startswith(line, "	optdepends_x86_64 = ")
            dep = line[22:end]
            push!(pkgdeps, clean_version(dep))

        # All provides: pkgbase, provides plus any additional 'x86_64' architecture-specific once.
        elseif startswith(line, "	provides = ")
            provide = line[13:end]
            push!(pkgprovides, clean_version(provide))
        elseif startswith(line, "	provides_x86_64 = ")
            provide = line[20:end]
            push!(pkgprovides, clean_version(provide))
        elseif startswith(line, "pkgbase = ")
            provide = line[11:end]
            push!(pkgprovides, clean_version(provide))
        end
    end

    # NOTE epoch is optional
    found_pkgver || throw(ArgumentError("\n\npkg: <$(pkg)> Could not extract any 'pkgver'.\n\n$(PKGBUILD_content)"))
    found_pkgrel || throw(ArgumentError("\n\npkg: <$(pkg)> Could not extract any 'pkgrel'.\n\n$(PKGBUILD_content)"))
    isempty(pkgnames) &&  throw(ArgumentError(string("\n\npkg: <$(pkg)> Could not extract any 'pkgname'.\n\n",
                                                     "$(PKGBUILD_content)")))
    return pkgbase, epoch, pkgver, pkgrel, pkgnames, pkgdeps, pkgprovides
end


"""
Print a FAZIT of packages which could not successfully be processed.
"""
function print_failed_fazit(needed_pkglist::Vector{UTF8String}, pkginfo::Dict, txt::AbstractString)
    if !isempty(needed_pkglist)
        sorted_needed_pkglist = sort(needed_pkglist)
        println("\n\n\n=== $(txt) FAZIT === Could not process: <$(length(needed_pkglist))> pkgs.")
        for pkg in sorted_needed_pkglist println("    Package: <$(pkg)> $(pkginfo[pkg]["absdir"])") end
        println("\n\nPackageList: <$(join(sorted_needed_pkglist, ' '))>\n\n")
    end
end


"""
Helper to print the FAZIT for the install function
"""
function print_install_fazit(resultlist::Vector, level::ASCIIString, pkgs_level_list::Vector, pkginfo_updated::Dict)
    println("\n\n**$(level)**: <$(length(pkgs_level_list))> pkgs.")
    if !isempty(resultlist)
        println("\n    Could not process: <$(length(resultlist))> pkgs.")
        for pkg in resultlist println("        Package: <$(pkg)> $(pkginfo_updated[pkg]["absdir"])") end
        println("\n  $(level) PackageList: <$(join(resultlist, ' '))>")
    else println("\n  Finished all packages of this level.") end
end


"""
Tries to remove any PACKMAN_DB_LOCK_PATH.
This does not check anything,

command1 = `echo sudo_password`
command2 = `sudo -S rm -f packman_db_lock_path`
"""
function remove_pacman_db_lock(sudo_password, packman_db_lock_path)
    # try to remove any PACKMAN_DB_LOCK_PATH
    cmd1 = `echo $sudo_password`
    cmd2 = `sudo -S rm -f $packman_db_lock_path`
    println("\n++++ TRYING +++ to remove any PACKMAN_DB_LOCK_PATH: <$(packman_db_lock_path) ",
            "using cmd1|cmd2: $cmd1 | $cmd2\n")
    ignorestatus(pipeline(cmd1, cmd2))
end


# ------------------------------------------------------------------------------------------------------------------- #


"""
Adds all 'provides' of a package in `dir` to the dictionary `d`.
Info is taken from `pkginfo`.
"""
function provides2pkgbase!(pkg, d::Dict, pkginfo::Dict)
    for provide in pkginfo[pkg]["pkgprovides"]
        haskey(d, provide) &&
                throw(ArgumentError(string("\n\npkg: <$(pkg)> Provides: <$(provide)> already ",
                                           "seen in pkg: <$(d[provide])>\n\n")))
        d[provide] = (pkg, pkginfo[pkg]["pkgbase"])
    end
end


"""
Returns dependency levels.

Tries to solve dependencies within the selected packages. All other dependencies are expected to be already provided.

Returns:

    `pkgs_level1::Vector`: no deps at all specified
                           => should be installed first
    `pkgs_level2::Vector`: no deps within the provided selection or only within the same basepackage
                           => should be installed second
    `pkgs_level3::Vector`: resolved dependencies within the provided selection: in any pkg of
                           level1, level2 or earlier in level3.
                           => can be installed afterwards in this order

    `pkgs_unsolved_deps::Dict:` packages with unsolveable dependencies within the provided selection.
                                => can not be installed

'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function dependency_solver(pkgdirlist::Vector{UTF8String}, pkginfo::Dict)
    provides2pkgbase_all_pkginfo = Dict()
    for pkg in pkgdirlist provides2pkgbase!(pkg, provides2pkgbase_all_pkginfo, pkginfo) end

    level1 = Set()
    level2 = Set()
    level3 = Vector() # this one needs to keep the order

    provides2pkgbase_already_solved = Dict()
    pkgs_unsolved_deps = Dict()   # value is a list of deps which are provided within the selection

    # === PRE-RUN
    # do level1 and level2
    for (pkg, v) in pkginfo
        pkgdeps = v["pkgdeps"]
        if isempty(pkgdeps)
            push!(level1, pkg)
            provides2pkgbase!(pkg, provides2pkgbase_already_solved, pkginfo)
        else
            got_dependency_in_selectedpkgs = false
            for dep in pkgdeps
                if dep in keys(provides2pkgbase_all_pkginfo)
                    # check if the pkg provides the dependency itself. e.g. some deps in split pkgs (pulseaudio_p).
                    dep in v["pkgprovides"] && continue

                    got_dependency_in_selectedpkgs = true
                    haskey(pkgs_unsolved_deps, pkg)         ?
                        push!(pkgs_unsolved_deps[pkg], dep) :
                        pkgs_unsolved_deps[pkg] = Set([dep])
                end
            end
            if !got_dependency_in_selectedpkgs
                push!(level2, pkg)
                provides2pkgbase!(pkg, provides2pkgbase_already_solved, pkginfo)
            end
        end
    end

    # Do the final level3 in order
    while true
        done_remove_pkgs = Set()
        for (pkg, deps_to_solve) in pkgs_unsolved_deps
            all_deps_satisfied = true
            for dep in deps_to_solve
                # TODO: Decide if we should remove any deps which can be satisfied so a next run does
                #       not have to redo them
                dep in keys(provides2pkgbase_already_solved) && continue
                # For now we can not solve it - maybe later
                all_deps_satisfied = false
                break
            end
            if all_deps_satisfied
                push!(level3, pkg)
                provides2pkgbase!(pkg, provides2pkgbase_already_solved, pkginfo)
                push!(done_remove_pkgs, pkg)
            end
        end
        # Remove the succesfull pkgs from the pkgs_unsolved_deps
        isempty(done_remove_pkgs) ? break : for _pkg in done_remove_pkgs delete!(pkgs_unsolved_deps, _pkg) end
    end

    if !isempty(pkgs_unsolved_deps)
        println("\n\n\n=== dependency_solver <FAZIT === Could not solve: <$(length(keys(pkgs_unsolved_deps)))> pkgs.")
        unsolved_pkgs = sort(collect(keys(pkgs_unsolved_deps)))
        for pkg in unsolved_pkgs println("    Package: <$(pkg)> $(pkginfo[pkg]["absdir"])") end
        println("\n\nPackageList: <$(join(unsolved_pkgs, ' '))>\n\n")
    end

    # IMPORTANT: do not sort level 3 as they are in the correct order.
    return (sort(Vector{UTF8String}(collect(level1))),
            sort(Vector{UTF8String}(collect(level2))),
            Vector{UTF8String}(collect(level3)),
            pkgs_unsolved_deps)
end

# ------------------------------------------------------------------------------------------------------------------- #

"""
Writes the current `pkginfo` (name, version etc.) to `pkginfo_file`
This can be a useful information if for instance a git package does not compile with the last checkout

'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function write_pkginfo(pkgdirlist::Vector{UTF8String}, pkginfo::Dict, pkginfo_file::ByteString)
    open(pkginfo_file, "w") do io
        println(io, "### Package Info: $(Libc.strftime(TIMEFORMAT, time()))")

        for pkg in pkgdirlist
            println(io, "\n#### Package: $(pkg)")
            println(io, "* **pkgbase**:  $(pkginfo[pkg]["pkgbase"])")
            println(io, "* **pkgver**:   $(pkginfo[pkg]["pkgver"])")
            println(io, "* **pkgrel**:   $(pkginfo[pkg]["pkgrel"])")
            pkginfo[pkg]["epoch"] == -1 || println(io, "* **epoch**: $(pkginfo[pkg]["epoch"])")

            println(io, "* **pkgnames**:")
            for name in pkginfo[pkg]["pkgnames"] println(io, "  * $(name)") end

            println(io, "* **all pkgdependencies**: *depends, makedepends, checkdepends, optdepends ",
                        "and any 'x86_64' architecture-specific once.*")
            for dep in sort(collect(pkginfo[pkg]["pkgdeps"])) println(io, "  * $(dep)") end

            println(io, "* **all pkgprovides**: *pkgbase,provides plus  ",
                        "any additional 'x86_64' architecture-specific once.*")
            for provide in sort(collect(pkginfo[pkg]["pkgprovides"])) println(io, "  * $(provide)") end
        end
    end
end


"""
Writes the output of 'namcap filearchive` to file `namcap_file`.
NOTE: This requires that previously some pkg where compiled: e.g. action: `build or install`

'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function write_namcap(pkgdirlist::Vector{UTF8String}, pkginfo::Dict, install_pkg_arch, pkgext, namcap_file::ByteString)
    open(namcap_file, "w") do io
        println(io, "### Package NAMCAP OUTPUT Info: $(Libc.strftime(TIMEFORMAT, time()))")

        for pkg in pkgdirlist
            println(io, "\n#### Package: $(pkg)\n")
            v = pkginfo[pkg]
            cd(v["absdir"])
            for arch in install_pkg_arch
                for name in v["pkgnames"]
                    package_file_str = string(name, "-",
                                              v["epoch"] == -1 ? "" : "$(v["epoch"]):",
                                              v["pkgver"],  "-",
                                              v["pkgrel"],  "-",
                                              arch,
                                              pkgext)
                    # check if it exists
                    package_file_path = joinpath(v["absdir"], package_file_str)
                    ispath(package_file_path) || continue

                    println(io, "  * $(name) > $(package_file_str)\n")
                    cmd = `namcap $package_file_path`
                    namcap_result = readall(cmd)
                    lines = split(namcap_result, '\n')
                    for line in lines println(io, "    $(line)\n") end
                end
            end
        end
    end
end


"""
 Writes dependency levels to file `dependency_level.md.`
Only included info is the one retrieved from the included PKGBUILD files.

This is very basic - good enough for now till a proper wrapper for pacman 'libalpm' is done.

'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function write_dependency_level(pkgdirlist::Vector{UTF8String}, pkginfo::Dict, dependency_level_file::ByteString)
    pkgs_level1, pkgs_level2, pkgs_level3, pkgs_unsolved_deps = dependency_solver(pkgdirlist, pkginfo)
    open(dependency_level_file, "w") do io
        println(io, "### Package Dependency Levels: $(Libc.strftime(TIMEFORMAT, time()))")
        println(io, "\nOnly included info is the one retrieved from the included PKGBUILD files.")

        println(io, "\n\n* **LEVEL 1 Packages**: no deps at all specified.")
        println(io, "\n  * **PackageList**: $(join(pkgs_level1, ' '))\n")
        for name in pkgs_level1 println(io, "    * $(name)") end

        println(io, "\n\n* **LEVEL 2 Packages**: no deps within the provided ",
                   "selection or only within the same basepackage.")
        println(io, "\n  * **PackageList**: $(join(pkgs_level2, ' '))\n")
        for name in pkgs_level2 println(io, "    * $(name)") end

        println(io, "\n\n* **LEVEL 3 Packages**: resolved dependencies within the provided ",
                    "selection: in any pkg of level1, level2 or earlier in level3.")
        println(io, "\n  * **PackageList**: $(join(pkgs_level3, ' '))\n")
        for name in pkgs_level3 println(io, "    * $(name)") end

        println(io, "\n\n* **UNSOLVED Packages**: packages with unsolveable dependencies ",
                    "within the provided selection.")
        println(io, "\n  * **PackageList**: $(join(pkgs_unsolved_deps, ' '))\n")
        for (name, deps) in pkgs_unsolved_deps
            println(io, "    * $(name)")
            for dep in deps println(io, "    * $(dep)") end
        end
    end
end


# ------------------------------------------------------------------------------------------------------------------- #


"""
This function is used for actions which only differ in the command or pkglist

'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function common_actions(pkgdirlist::Vector{UTF8String}, pkginfo::Dict, infotxt::AbstractString, cmd::Cmd)
    needed_pkglist = deepcopy(pkgdirlist)
    counter = 0
    while true
        length_needed_pkglist = length(needed_pkglist)
        remove_pkgs_idxs = Vector{Integer}()
        println("\n\n\n>#>#>#> $(infotxt) !! NUMBER OF PACKAGES TO PROCESS: <$(length_needed_pkglist)>")
        println("                   USING CMD: ", cmd)

        for (index, pkg) in enumerate(needed_pkglist)
            cd(pkginfo[pkg]["absdir"])
            println(string("\n\n  >>>$(infotxt)<<< processing pkg: <$(index)/$(length_needed_pkglist)> ",
                           "pkg: <$(pkg)>  START-TIME: <$(Libc.strftime(TIMEFORMAT, time()))>"))
            if success(cmd)
                println("\n            * $(infotxt): SUCCESS")
                push!(remove_pkgs_idxs, index)
            else
                println("\n        * $(infotxt) FAILD: will retry later")
            end
        end

        if isempty(remove_pkgs_idxs)
            # Remove the succesfull pkgs from the needed_pkglist - if none was succesfull try at least 1 time
            (isempty(needed_pkglist) || counter >= 1) && break
            counter += 1
        else deleteat!(needed_pkglist, remove_pkgs_idxs) end
    end

    print_failed_fazit(needed_pkglist, pkginfo, infotxt)
end


"""
Removes the pkg without any checks. **ATTENTION**: Potentially breaking the Operating system.

* command: `pacman -Rdd pkgname`
'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function remove_pkgs(pkgdirlist::Vector{UTF8String}, pkginfo::Dict, sudo_password, packman_db_lock_path)
    remove_pacman_db_lock(sudo_password, packman_db_lock_path)

    needed_pkglist = deepcopy(pkgdirlist)
    length_needed_pkglist = length(needed_pkglist)
    println("\n\n\n>#>#>#> REMOVE !! NUMBER OF PACKAGES TO PROCESS: <$(length_needed_pkglist)>")
    println("                   USING CMD: ", `echo $sudo_password`, " | ", `sudo -S pacman --noconfirm -Rdd pkgname`)

    for (index, pkg) in enumerate(needed_pkglist)
        println(string("\n\n  >>>REMOVE<<< processing pkg: <$(index)/$(length_needed_pkglist)> pkg: ",
                       "<$(pkg)>  START-TIME: <$(Libc.strftime(TIMEFORMAT, time()))>"))
        for pkgname in pkginfo[pkg]["pkgnames"]
            cmd1 = `echo $sudo_password`
            cmd2 = `sudo -S pacman --noconfirm -Rdd $pkgname`
            println("\n    * REMOVING: <$(pkgname)> using cmd1|cmd2: $cmd1 | $cmd2")
            println("            PACKAGE PATH: <$(pkginfo[pkg]["absdir"])>")
            if success(pipeline(cmd1, cmd2))
                println("\n            * REMOVE: SUCCESS")
            else
                println("\n        * REMOVE FAILD: will retry.")
                readall(ignorestatus(pipeline(cmd1, cmd2)))
            end
        end
    end
end


"""
Downloads first all needed sources - than builds and installs one pkg after another.
**ATTENTION**: force install, overwrite conflicting files. Potentially breaking the Operating system.

* getsource command: `makepkg --noconfirm --nobuild --nodeps --noprepare`
* build command: `makepkg --noconfirm --force --clean --cleanbuild --holdver --log`
* install command: `pacman --noconfirm --force -U pkgfile`

* ATTENTION: if `holdver` is true it will hold the version (does not update) VCS sources at the getsource part

'pkgdirlist': must be a valid sorted one: see `validate_pkglist()`
"""
function install_pkgs(pkgdirlist::Vector{UTF8String}, pkginfo::Dict, sudo_password, packman_db_lock_path,
                      install_pkg_arch, pkgext, holdver::AbstractString, startdir::AbstractString)
    # First try to get for all packages the source: in case the package version changes for git, svn etc.. sources
    holdver_bool = holdver == "--holdver" ? true : false
    common_actions(pkgdirlist, pkginfo, "GETSOURCE (install:holdver: $(holdver_bool))",
                   `makepkg --noconfirm --nobuild --nodeps --noprepare $(holdver)`)
    # IMPORTANT: for the next step we need to go back into the startdir
    cd(startdir)

    # Re-do once more the: get_pkginfo to get any updated version values.
    pkginfo_updated = get_pkginfo(pkgdirlist)
    pkgs_level1, pkgs_level2, pkgs_level3, pkgs_unsolved_deps = dependency_solver(pkgdirlist, pkginfo_updated)

    println("\n\n\n=== BUILD/INSTALL OVERVIEW ===")

    println("\n\nLEVEL 1 Packages: no deps at all specified.")
    for name in pkgs_level1 println("  * $(name)") end
    println("\nLEVEL 1 PackageList: <$(join(pkgs_level1, ' '))>\n")

    println("\n\nLEVEL 2 Packages: no deps within the provided ",
               "selection or only within the same basepackage.")
    for name in pkgs_level2 println("  * $(name)") end
    println("\nLEVEL 2 PackageList: <$(join(pkgs_level2, ' '))>\n")

    println("\n\nLEVEL 3 Packages: resolved dependencies within the provided ",
                "selection: in any pkg of level1, level2 or earlier in level3.")
    for name in pkgs_level3 println("  * $(name)") end
    println("\nLEVEL 3 PackageList: <$(join(pkgs_level3, ' '))>\n")

    println("\n\nSKIPPING UNSOLVED Packages: packages with unsolveable dependencies within the provided selection.")
    for (name, deps) in pkgs_unsolved_deps
        println("  * $(name)")
        for dep in deps println("    * $(dep)") end
    end

    # build/install LEVEL 1
    res1 = _install_common(pkgs_level1, pkginfo_updated, sudo_password,
                           packman_db_lock_path, install_pkg_arch, pkgext, "LEVEL 1")

    # build/install LEVEL 2
    res2 = _install_common(pkgs_level2, pkginfo_updated, sudo_password,
                           packman_db_lock_path, install_pkg_arch, pkgext, "LEVEL 2")

    # build/install LEVEL 3
    res3 = _install_common(pkgs_level3, pkginfo_updated, sudo_password,
                           packman_db_lock_path, install_pkg_arch, pkgext, "LEVEL 3")

    # -----------------------------------------------------------------------------------------------------------

    println("\n\n\n=== BUILD/INSTALL FAZIT ===")
    print_install_fazit(res1, "LEVEL 1", pkgs_level1, pkginfo_updated)
    print_install_fazit(res2, "LEVEL 2", pkgs_level2, pkginfo_updated)
    print_install_fazit(res3, "LEVEL 3", pkgs_level3, pkginfo_updated)

    println("\n\n**UNSOLVED DEPENDENCIES**: <$(length(pkgs_unsolved_deps))> pkgs.")
    if !isempty(pkgs_unsolved_deps)
        unsolved_pkgs = sort(collect(keys(pkgs_unsolved_deps)))
        for pkg in unsolved_pkgs
            println("\n   Package: <$(pkg)> $(pkginfo_updated[pkg]["absdir"])")
            for dep in pkgs_unsolved_deps[pkg] println("       * dep: $(dep)") end
        end
        println("\n  UNSOLVED DEPENDENCIES PackageList: <$(join(unsolved_pkgs, ' '))>\n\n")
    else println("\n    There where no packages with unsolved dependencies.") end
end


"""
Internal usage do not call this directly
"""
function _install_common(pkgdirlist::Vector{UTF8String}, pkginfo::Dict, sudo_password,
                         packman_db_lock_path, install_pkg_arch, pkgext, level::ASCIIString)

    remove_pacman_db_lock(sudo_password, packman_db_lock_path)

    needed_pkglist = deepcopy(pkgdirlist)
    # Now we will hold the version: `--holdver`        Do not update again any VCS sources
    cmd_build = `makepkg --noconfirm --force --clean --cleanbuild --holdver --log`
    counter = 0
    while true
        length_needed_pkglist = length(needed_pkglist)
        remove_pkgs_idxs = Vector{Integer}()
        println("\n\n\n>#>#>#> BUILD/INSTALL !! $(level) !! NUMBER OF PACKAGES TO PROCESS: <$(length_needed_pkglist)>")
        println("                   USING BUILD CMD: ", cmd_build)

        for (index, pkg) in enumerate(needed_pkglist)
            start_time = time()
            v = pkginfo[pkg]
            cd(v["absdir"])
            println(string("\n\n  >>>BUILD $(level)<<< processing pkg: <$(index)/$(length_needed_pkglist)> pkg: ",
                           "<$(pkg)>  START-TIME: <$(Libc.strftime(TIMEFORMAT, start_time))>"))
            if success(cmd_build)
                println("\n            * BUILD: SUCCESS >>> trying to install now.")
                # INSTALL THEM
                package_files = []
                for arch in install_pkg_arch
                    for pkgname in v["pkgnames"]
                        package_file_str = string(pkgname, "-",
                                v["epoch"] == -1 ? "" : "$(v["epoch"]):",
                                v["pkgver"],  "-",
                                v["pkgrel"],  "-",
                                arch,
                                pkgext)
                        package_file_path = joinpath(v["absdir"], package_file_str)
                        isfile(package_file_path) && push!(package_files, package_file_str)
                    end
                end

                cmd1 = `echo $sudo_password`
                cmd2 = `sudo -S pacman --noconfirm --force -U $package_files`
                println("\n        * INSTALL: using cmd1|cmd2: $cmd1 | $cmd2")
                if success(pipeline(cmd1, cmd2))
                    println("\n            * INSTALLED: SUCCESS")
                    push!(remove_pkgs_idxs, index)
                else
                    println("\n        * INSTALL FAILD: will retry later")
                end
                println("\n        !!!EXEUTION TIME!!  was: <$(round((time() - start_time) / 60.0, 0))> minutes.")
            else
                println("\n        * BUILD/INSTALL FAILD: will retry later")
            end
        end

        if isempty(remove_pkgs_idxs)
            # Remove the succesfull pkgs from the needed_pkglist - if none was succesfull try at least 1 time
            (isempty(needed_pkglist) || counter >= 1) && break
            counter += 1
            # try to remove any PACKMAN_DB_LOCK_PATH
            remove_pacman_db_lock(sudo_password, packman_db_lock_path)
        else deleteat!(needed_pkglist, remove_pkgs_idxs) end
    end

    return sort(needed_pkglist)
end


"""
Main entry checks also commandline arguments..
"""
function main(usage_txt, packman_db_lock_path, install_pkg_arch, pkgext)
    help_idx = findfirst(ARGS, "--help")
    if help_idx > 0
        println(usage_txt)
        exit()
    end

    main_start_time = time()
    STARTDIR = Base.source_dir()
    cd(STARTDIR)   # in case in the future we allow different startdirs

    length_options = length(ARGS)
    length_options < 2 &&
            throw(ArgumentError(string(usage_txt,
                                       "\n\n\n**ERROR** Expected minimum 2 arguments. Got: <$(length_options)>",
                                       "\n    ARGS: $ARGS\n\n")))
    SUDO_PASSWORD = ARGS[1]
    ACTION_TYPE = ARGS[2]
    DO_PKG = []

    # holdver --holdver
    holdversion_idx = findfirst(ARGS, "--holdver")
    HOLDVERSION = holdversion_idx > 0 ? "--holdver" : ""

    # find --pkginfo
    PKGINFO_FILE = ""
    pkginfo_idx = findfirst(ARGS, "--pkginfo")
    if pkginfo_idx > 0
        length_options > pkginfo_idx             ?
            PKGINFO_FILE = ARGS[pkginfo_idx + 1] :
            throw(ArgumentError(string("$(usage_txt)\n\n\n**ERROR** option `--pkginfo` was set but no file path:",
                                       "\n    ARGS: $ARGS\n\n")))
    end

    # find --dopkg
    dopkg_idx = findfirst(ARGS, "--dopkg")
    dopkg_idx > 0 ? length_options > dopkg_idx && (DO_PKG = ARGS[dopkg_idx + 1:end]) : DO_PKG = readdir(STARTDIR)

    # RUN IT
    PKGDIRLIST = validate_pkglist(DO_PKG)
    PKGINFO = get_pkginfo(PKGDIRLIST)

    # WRITE ANY PKGINFO to file FILE
    isempty(PKGINFO_FILE) || write_pkginfo(PKGDIRLIST, PKGINFO, PKGINFO_FILE)

    println("\n\n\nSET TO `$(uppercase(ACTION_TYPE))` PACKAGES: <$(length(PKGDIRLIST))>")
    for pkg in PKGDIRLIST println("    $pkg") end
    println("\nPackageList: <$(join(PKGDIRLIST, ' '))>\n")

    if ACTION_TYPE == "writepkginfo"
        reply = input(string("\n\n!!! WRITEPKGINFO !! Writes the current pkginfo (name, version etc.) to file ",
                "`PKGINFO.md.`",
                "\n\n    To continue type 'YES': "))
        reply == "YES" ? write_pkginfo(PKGDIRLIST, PKGINFO, "PKGINFO.md") : exit()

    elseif ACTION_TYPE == "writenamcap"
        reply = input(string("\n\n!!! WRITENAMCAP !! Writes the output of 'namcap filearchive` to file ",
                "`NAMCAP_PKG_OUTPUT.md`. `NAMCAP_PKG_OUTPUT.md`",
                "\n\n    To continue type 'YES': "))
        reply == "YES" ? write_namcap(PKGDIRLIST, PKGINFO, install_pkg_arch, pkgext, "NAMCAP_PKG_OUTPUT.md") : exit()

    elseif ACTION_TYPE == "writedeps"
        reply = input(string("\n\n!!! WRITEDEPS !! Writes dependency levels to file `DEPENDENCY_LEVEL.md.`",
                "\nOnly included info is the one retrieved from the included PKGBUILD files.`",
                "\n\n    To continue type 'YES': "))
        reply == "YES" ? write_dependency_level(PKGDIRLIST, PKGINFO, "DEPENDENCY_LEVEL.md") : exit()

    elseif ACTION_TYPE == "getsources"
        reply = input(string("\n\n!!! GETSOURCES !! Only download the sources - updates PKGBUILD version.",
                "\n         see also optional argument: --holdver",
                "\n\n    To continue type 'YES': "))
        if reply == "YES"
            common_actions(PKGDIRLIST, PKGINFO, "GETSOURCES",
                           `makepkg --noconfirm --nobuild --nodeps --noprepare $(HOLDVERSION)`)
        else exit() end

    elseif ACTION_TYPE == "allsourcetar"
        reply = input(string("\n\n!!! ALLSOURCETAR !! Generate pkgbuild tarball including downloaded sources.",
                "\n         see also optional argument: --holdver",
                "\n\n    To continue type 'YES': "))
        if reply == "YES"
            common_actions(PKGDIRLIST, PKGINFO, "ALLSOURCETAR",
                           `makepkg --noconfirm --force --nodeps --allsource $HOLDVERSION`)
        else exit() end

    elseif ACTION_TYPE == "pkgbuildtar"
        reply = input(string("\n\n!!! PKGBUILDTAR !! Generate pkgbuild tarball without downloaded sources.",
                "\n    This is similar to the old AUR package archives.",
                "\n         see also optional argument: --holdver",
                "\n\n    To continue type 'YES': "))
        if reply == "YES"
            common_actions(PKGDIRLIST, PKGINFO, "PKGBUILDTAR", `makepkg --noconfirm --force --source $HOLDVERSION`)
        else exit() end

    elseif ACTION_TYPE == "build"
        reply = input(string("\n\n!!! BUILD !! Downloads sources and builds them.",
                "\n         see also optional argument: --holdver",
                "\n    Note: This does not install anything. ",
                "\n          If packages depend on others among the list they will not build.",
                "\n\n    To continue type 'YES': "))
        if reply == "YES"
            common_actions(PKGDIRLIST, PKGINFO, "BUILD",
                           `makepkg --noconfirm --force --clean --cleanbuild --log $HOLDVERSION`)
        else exit() end

    elseif ACTION_TYPE == "remove"
        reply = input(string("\n\n!!! REMOVE !! Removes the pkg without any checks.",
                "\n    ATTENTION: Potentially breaking the Operating system.",
                "\n        remove command: `pacman -Rdd pkgname`",
                "\n",
                "\n        This will also try to remove any PACKMAN_DB_LOCK_PATH file: <$(packman_db_lock_path)>",
                "\n                           Make sure no other process accesses it.",
                "\n\n    To continue type 'YES': "))
        reply == "YES" ? remove_pkgs(PKGDIRLIST, PKGINFO, SUDO_PASSWORD, packman_db_lock_path) : exit()

    elseif ACTION_TYPE == "install"
        reply = input(string("\n\n!!! INSTALL !! Downloads first all needed sources - than builds and installs one",
                " pkg after another.",
                "\n    ATTENTION: force install, overwrite conflicting files.  Potentially breaking the system.",
                "\n        getsource command: `makepkg --noconfirm --nobuild --nodeps --noprepare`",
                "\n         see also optional argument: --holdver",
                "\n        build command: `makepkg --noconfirm --force --clean --cleanbuild --holdver --log`",
                "\n        install command: `pacman --noconfirm --force -U pkgfile`",
                "\n",
                "\n        This will also try to remove any PACKMAN_DB_LOCK_PATH file: <$(packman_db_lock_path)>",
                "\n                           Make sure no other process accesses it.",
                "\n\n    To continue type 'YES': "))
        if reply == "YES"
            install_pkgs(PKGDIRLIST, PKGINFO, SUDO_PASSWORD, packman_db_lock_path,
                         install_pkg_arch, pkgext, HOLDVERSION, STARTDIR)

        else exit() end

    else
        throw(ArgumentError(string(usage_txt,
                                   "\n\n\n**ERROR** ACTION_TYPE: (2nd argument) seems not supported.",
                                   " Got: <$(ACTION_TYPE)>\n\n")))
    end

    main_end_time = time()
    println("\n\n\n!!!COMPLETE EXEUTION TIME was:!!! <",
            round((main_end_time - main_start_time) / 60.0, 0), "> minutes.\n\n")
end


# ------------------------------------------------------------------------------------------------------------------- #
main(USAGE_TXT, PACKMAN_DB_LOCK_PATH, INSTALL_PKG_ARCH, PKGEXT)
