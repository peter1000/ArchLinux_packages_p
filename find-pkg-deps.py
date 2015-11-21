#!/usr/bin/env python

"""
This file is taken from the aur pkg: mpv-git


Usage: find-deps.py <binary> [<binary> ...]

Finds (pacman/ALPM) dependencies for a binary or set of binaries based on dynamically linked libraries.

"""

import sys
import subprocess
import re

def subprocess_get_lines(args, fail_okay=False):
    try:
        output = subprocess.check_output(args)
    except subprocess.CalledProcessError as e:
        if fail_okay:
            output = e.output
        else:
            raise
    return output.decode().splitlines()

# Get the filenames of the libs we need
ldd_output = subprocess_get_lines(['ldd'] + sys.argv[1:])
regex = re.compile(r' => (.*) \(0x[0-9a-f]+\)$')
libs = set(match.group(1) for match in map(regex.search, ldd_output) if match)

# Figure out which packages own them
deps = set(subprocess_get_lines(
    ['pacman', '--query', '--owns', '--quiet'] + list(libs),
    fail_okay=True
))

# fakeroot will be linked when building with makepkg, but isn't really needed
deps.discard('fakeroot')

# Remove redundant dependencies
needed = set(deps)
for pkg in deps:
    if pkg not in needed:
        continue # this subtree has already been pruned
    redundant = subprocess_get_lines(
        ['pactree', '--unique', pkg]
    )[1:] # first line is pkg itself
    needed.difference_update(redundant)

print(' '.join(sorted(needed)))
