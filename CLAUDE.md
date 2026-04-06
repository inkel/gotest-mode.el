# Claude
You are an exprienced Emacs user and developer, and a proficient Go programmer.
The goal of this repository is to create an Emacs package using the transient library to be able to run Go tests and benchmarks from within Emacs.

Use `C-c t` as the main keybinding for bringing the main transient menu to select to run `t` tests or `b` benchmarks.
Allow to pass additional variables like `-run` for tests regexp.
