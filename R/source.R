#' Compile Rust code and call from R
#'
#' [rust_source()] compiles and loads a single Rust file for use in R. [rust_function()]
#' compiles and loads a single Rust function for use in R.
#'
#' @param file Input rust file to source.
#' @param code Input rust code, to be used instead of `file`.
#' @param dependencies Character vector of dependencies lines to be added to the
#'   `Cargo.toml` file.
#' @param patch.crates_io Character vector of patch statements for crates.io to
#'   be added to the `Cargo.toml` file.
#' @param profile Rust profile. Can be either `"dev"` or `"release"`. The default,
#'   `"dev"`, compiles faster but produces slower code.
#' @param extendr_version Version of the extendr-api crate, provided as a Rust
#'   version string. `"*"` will use the latest available version on crates.io.
#' @param extendr_macros_version Version of the extendr-macros crate, if different
#'   from `extendr_version`.
#' @param env The R environment in which the wrapping functions will be defined.
#' @param use_extendr_api Logical indicating whether `use extendr_api::*;` should
#'   be added at the top of the Rust source provided via `code`. Default is `TRUE`.
#'   Ignored for Rust source provided via `file`.
#' @param cache_build Logical indicating whether builds should be cached between
#'   calls to [rust_source()].
#' @param quiet Logical indicating whether compile output should be generated or not.
#' @return The result from [dyn.load()], which is an object of class `DLLInfo`. See
#'   [getLoadedDLLs()] for more details.
#' @examples
#' \dontrun{
#' # creating a single rust function
#' rust_function("fn add(a:f64, b:f64) -> f64 { a + b }")
#' add(2.5, 4.7)
#'
#' # creating multiple rust functions at once
#' code <- r"(
#' #[extendr]
#' fn hello() -> &'static str {
#'     "Hello, world!"
#' }
#'
#' #[extendr]
#' fn test( a: &str, b: i64) {
#'     rprintln!("Data sent to Rust: {}, {}", a, b);
#' }
#' )"
#'
#' rust_source(code = code)
#' hello()
#' test("a string", 42)
#'
#'
#' # use case with an external dependency: a function that converts
#' # markdown text to html, using the `pulldown_cmark` crate.
#' code <- r"(
#'   use pulldown_cmark::{Parser, Options, html};
#'
#'   #[extendr]
#'   fn md_to_html(input: &str) -> String {
#'     let mut options = Options::empty();
#'     options.insert(Options::ENABLE_TABLES);
#'     let parser = Parser::new_ext(input, options);
#'     let mut output = String::new();
#'     html::push_html(&mut output, parser);
#'     output
#'   }
#' )"
#' rust_source(code = code, dependencies = 'pulldown-cmark = "0.8"')
#'
#' md_text <- "# The story of the fox
#' The quick brown fox **jumps over** the lazy dog.
#' The quick *brown fox* jumps over the lazy dog."
#'
#' md_to_html(md_text)
#' }
#' @export
rust_source <- function(file, code = NULL, dependencies = NULL,
                        patch.crates_io = c(
                          'extendr-api = { git = "https://github.com/extendr/extendr" }',
                          'extendr-macros = { git = "https://github.com/extendr/extendr" }'
                        ),
                        profile = c("dev", "release"), extendr_version = "*",
                        extendr_macros_version = extendr_version,
                        env = parent.frame(),
                        use_extendr_api = TRUE,
                        cache_build = TRUE, quiet = FALSE) {
  profile <- match.arg(profile)
  dir <- get_build_dir(cache_build)
  if (!isTRUE(quiet)) {
    message(sprintf("build directory: %s\n", dir))
    stdout <- "" # to be used by `system2()` below
  } else {
    stdout <- NULL
  }

  # copy rust code into src/lib.rs and determine library name
  rust_file <- file.path(dir, "src", "lib.rs")
  if (!is.null(code)) {
    if (isTRUE(use_extendr_api)) {
      code <- paste0("use extendr_api::*;\n\n", code)
    }
    brio::write_lines(code, rust_file)

    # generate lib name
    libname <- paste0("rextendr", the$count)
    the$count <- the$count + 1L
  } else {
    file.copy(file, rust_file, overwrite = TRUE)
    libname <- tools::file_path_sans_ext(basename(file))
  }

  if (!isTRUE(cache_build)) {
    on.exit(clean_build_dir())
  }

  # generate Cargo.toml file and compile shared library
  cargo.toml_content <- generate_cargo.toml(
    libname, dependencies, patch.crates_io,
    extendr_version, extendr_macros_version
  )
  brio::write_lines(cargo.toml_content, file.path(dir, "Cargo.toml"))

  # Get target name, not null for Windows
  specific_target <- get_specific_target_name()

  status <- system2(
    command = "cargo",
    args = c(
      "build",
      "--lib",
      if (!is.null(specific_target)) sprintf("--target %s", specific_target) else NULL,
      sprintf("--manifest-path %s", file.path(dir, "Cargo.toml")),
      sprintf("--target-dir %s", file.path(dir, "target")),
      if (profile == "release") "--release" else NULL
    ),
    stdout = stdout,
    stderr = stdout
  )
  if (status != 0L) {
    stop("Rust code could not be compiled successfully. Aborting.", call. = FALSE)
  }


  # generate R bindings for shared library
  funs <- get_exported_functions(rust_file) # extract function declarations
  r_functions <- generate_r_functions(funs)
  r_path <- file.path(dir, "R", "rextendr.R")
  brio::write_lines(r_functions, r_path)
  source(r_path, local = env)

  # load shared library
  libfilename <- if (.Platform$OS.type == "windows") {
    paste0(libname, get_dynlib_ext())
  } else {
    paste0("lib", libname, get_dynlib_ext())
  }

  target_folder <- ifelse(
    is.null(specific_target),
    "target",
    sprintf("target%s%s", .Platform$file.sep, specific_target)
  )

  shared_lib <- file.path(
    dir,
    target_folder,
    ifelse(profile == "dev", "debug", "release"),
    libfilename)
  dyn.load(shared_lib, local = TRUE, now = TRUE)
}

#' @rdname rust_source
#' @param ... Other parameters handed off to [rust_source()].
#' @export
rust_function <- function(code, env = parent.frame(), ...) {
  code <- paste0("#[extendr]\n", code)
  rust_source(code = code, env = env, ...)
}

generate_cargo.toml <- function(libname = "rextendr", dependencies = NULL, patch.crates_io = NULL,
                                extendr_version = "*", extendr_macros_version = extendr_version) {
  cargo.toml <- c(
    '[package]',
    glue::glue('name = "{libname}"'),
    'version = "0.0.1"\nedition = "2018"',
    '[lib]\ncrate-type = ["cdylib"]',
    '[dependencies]',
    glue::glue('extendr-api = "{extendr_version}"'),
    glue::glue('extendr-macros = "{extendr_macros_version}"')
  )

  # add user-provided dependencies
  cargo.toml <- c(cargo.toml, dependencies)

  # add user-provided patch.crates-io statements
  cargo.toml <- c(
    cargo.toml,
    "[patch.crates-io]",
    patch.crates_io
  )

  cargo.toml
}

get_dynlib_ext <- function() {
  # .Platform$dynlib.ext is not reliable on OS X, so need to work around it
  sysinf <- Sys.info()
  if (!is.null(sysinf)){
    os <- sysinf['sysname']
    if (os == 'Darwin')
      return(".dylib")
  }
  .Platform$dynlib.ext
}

get_specific_target_name <- function() {
  sysinf <- Sys.info()

  if  (!is.null(sysinf) && sysinf["sysname"] == "Windows") {
    if (R.version$arch == "x86_64") {
      return("x86_64-pc-windows-gnu")
    }

    if (R.version$arch == "i386") {
      return("i686-pc-windows-gnu")
    }

    stop("Unknown Windows architecture", call. = FALSE)
  }

  return(NULL)
}

the <- new.env(parent = emptyenv())
the$build_dir <- NULL
the$count <- 1L

get_build_dir <- function(cache_build) {
  if (!isTRUE(cache_build)) {
    clean_build_dir()
  }

  if (is.null(the$build_dir)) {
    dir <- tempfile()
    dir.create(dir)
    dir.create(file.path(dir, "R"))
    dir.create(file.path(dir, "src"))
    the$build_dir <- dir
  }
  the$build_dir
}

clean_build_dir <- function() {
  if (!is.null(the$build_dir)) {
    unlink(the$build_dir, recursive = TRUE)
    the$build_dir <- NULL
  }
}
