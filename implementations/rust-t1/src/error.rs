// Crate-wide error type.

use std::fmt;

#[derive(Debug, Clone)]
pub struct Error(pub String);

impl Error {
    pub fn new(msg: impl Into<String>) -> Error {
        Error(msg.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(&self.0)
    }
}

pub type Result<T> = std::result::Result<T, Error>;

macro_rules! err {
    ($($arg:tt)*) => { Err($crate::error::Error::new(format!($($arg)*))) };
}
pub(crate) use err;
