// The remote's sound: the Training Confirm echoes the server's wPackSize, the size of the whole
// Training PDU ([MS-RDPEA] 2.2.3.2). It sent the length of the data after the fields, 8 bytes short,
// and GNOME Remote Desktop rejects any other value and then plays nothing. The vendored
// ironrdp-rdpsnd's fix (vendor/ironrdp-rdpsnd/NOTICE-ZESTSSH; upstream IronRDP f86e3c49f3).
#![cfg(feature = "sound")]

use ironrdp_pdu::decode;
use ironrdp_rdpsnd::client::{NoopRdpsndBackend, Rdpsnd};
use ironrdp_rdpsnd::pdu::{self, AudioFormat, WaveFormat};
use ironrdp_pdu::encode_vec;
use ironrdp_svc::SvcProcessor as _;

fn waiting_client() -> Rdpsnd {
    let mut client = Rdpsnd::new(Box::new(NoopRdpsndBackend));
    let formats = encode_vec(&pdu::ServerAudioOutputPdu::AudioFormat(pdu::ServerAudioFormatPdu {
        version: pdu::Version::V8,
        formats: vec![AudioFormat {
            format: WaveFormat::PCM,
            n_channels: 2,
            n_samples_per_sec: 44100,
            n_avg_bytes_per_sec: 44100 * 4,
            n_block_align: 4,
            bits_per_sample: 16,
            data: None,
        }],
    }))
    .unwrap();
    client.process(&formats).unwrap();
    client
}

#[test]
fn the_training_confirm_echoes_the_servers_pack_size() {
    // Windows: 8 bytes of header and fields, then 1016 of data, wPackSize 1024 (MS-RDPEA 4.1.3).
    let data_len: u16 = 1016;
    let mut training = vec![0x06, 0x00]; // SNDC_TRAINING, bPad
    training.extend_from_slice(&(4 + data_len).to_le_bytes()); // BodySize
    training.extend_from_slice(&0x1234u16.to_le_bytes()); // wTimeStamp
    training.extend_from_slice(&1024u16.to_le_bytes()); // wPackSize
    training.extend(core::iter::repeat_n(0, usize::from(data_len)));

    let mut client = waiting_client();
    let responses = client.process(&training).unwrap();
    assert_eq!(responses.len(), 1);
    let encoded = responses[0].encode_unframed_pdu().unwrap();
    let confirm: pdu::ClientAudioOutputPdu = decode(&encoded).unwrap();
    let pdu::ClientAudioOutputPdu::TrainingConfirm(confirm) = confirm else {
        panic!("expected a Training Confirm, got {confirm:?}");
    };
    assert_eq!((confirm.timestamp, confirm.pack_size), (0x1234, 1024));
}
