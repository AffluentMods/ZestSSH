// A dynamic channel the client declines: data the server sent for it before it read the decline
// is dropped, not the end of the session (GNOME Remote Desktop sends on AUDIO_PLAYBACK_DVC right
// after asking to open it, and a session ended about a second after connecting). The vendored
// ironrdp-dvc's fix (vendor/ironrdp-dvc/NOTICE-ZESTSSH; upstream IronRDP a7ab89bd84).
#![cfg(feature = "rdp")]

use ironrdp_dvc::pdu::{
    CapabilitiesRequestPdu, CapsVersion, ClosePdu, CreateRequestPdu, CreationStatus, DataPdu, DrdynvcClientPdu,
    DrdynvcDataPdu, DrdynvcServerPdu,
};
use ironrdp_dvc::DrdynvcClient;
use ironrdp_pdu::{encode_vec, Decode as _, ReadCursor};
use ironrdp_svc::{SvcMessage, SvcProcessor as _};

fn decode_client_pdu(message: &SvcMessage) -> DrdynvcClientPdu {
    let encoded = message.encode_unframed_pdu().expect("DVC response should encode");
    DrdynvcClientPdu::decode(&mut ReadCursor::new(&encoded)).expect("DVC response should decode")
}

fn data(channel_id: u32, payload: &[u8]) -> Vec<u8> {
    encode_vec(&DrdynvcServerPdu::Data(DrdynvcDataPdu::Data(DataPdu::new(channel_id, payload.to_vec()))))
        .expect("DVC data should encode")
}

#[test]
fn data_for_a_channel_the_client_declined_is_dropped() {
    let mut client = DrdynvcClient::new();
    let caps = encode_vec(&DrdynvcServerPdu::Capabilities(CapabilitiesRequestPdu::new(CapsVersion::V3, None)))
        .expect("Capabilities Request should encode");
    client.process(&caps).expect("Capabilities Request should be processed");

    let create = encode_vec(&DrdynvcServerPdu::Create(CreateRequestPdu::new(4, "AUDIO_PLAYBACK_DVC".to_owned())))
        .expect("Create Request should encode");
    let responses = client.process(&create).expect("a channel without a listener is declined");
    let DrdynvcClientPdu::Create(response) = decode_client_pdu(&responses[0]) else {
        panic!("expected a Create Response");
    };
    assert_eq!(response.creation_status(), CreationStatus::NO_LISTENER);

    // What the server sent before it read the decline: dropped.
    assert!(
        client
            .process(&data(4, b"declined"))
            .expect("data for a declined channel is dropped, not an error")
            .is_empty()
    );
    // A channel the server never created is still an error.
    client.process(&data(5, b"never created")).expect_err("data for a channel never created");

    // The server's Close settles the decline: data after it is an error again.
    let close = encode_vec(&DrdynvcServerPdu::Close(ClosePdu::new(4))).expect("Close should encode");
    client.process(&close).expect("Close should be processed");
    client.process(&data(4, b"after close")).expect_err("data for a channel that is fully closed");
}
