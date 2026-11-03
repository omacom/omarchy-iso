# Trust list for our own runners.
#
# The install test runs on Omarchy's Namespace runners only for an author we
# trust: repository collaborators with write access are trusted automatically
# and do not need listing; external contributors listed here are trusted too.
# Of the bots, only Dependabot and GitHub Actions are (the workflow names them).
# Anyone else gets GitHub's runner. The list is read from the default branch,
# so a pull request cannot vouch for itself.
#
# Syntax:
#   github:username
#   -github:username reason for denouncement
#
# Keep entries sorted alphabetically. Started from omarchy-pkgs' list.
github:bjarneo
github:DanWahlin
github:dhh
github:f-trycua
github:HANCORE-linux
github:kwilczynski
github:ryanrhughes
github:scottjones
github:spencerbull
github:tcballard
github:tobi
