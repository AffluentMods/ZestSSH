mod cursor;
mod raw;
mod rre;
mod tight;
mod trle;
mod zlib;
mod zrle;
pub(crate) use cursor::Decoder as CursorDecoder;
pub(crate) use raw::Decoder as RawDecoder;
pub(crate) use rre::{HextileDecoder, RreDecoder, ZlibRawDecoder};
pub(crate) use tight::Decoder as TightDecoder;
pub(crate) use trle::Decoder as TrleDecoder;
pub(crate) use zrle::Decoder as ZrleDecoder;
#[cfg(fuzzing)]
pub(crate) use tight::decode_jpeg;

fn initialized_vec(len: usize) -> Vec<u8> {
    vec![0; len]
}

#[cfg(test)]
mod tests;
