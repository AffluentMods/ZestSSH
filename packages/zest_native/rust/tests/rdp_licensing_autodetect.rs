// RDS licensing on Windows Server 2022: an RD Session Host sends an Auto-Detect Request on the
// message channel in the middle of the licensing exchange, and the connector ended the connection
// with "invalid security header flags" (IronRDP issue #1629). The vendored ironrdp-connector's fix
// (vendor/ironrdp-connector/NOTICE-ZESTSSH; upstream IronRDP 905c28b3a4, #2128): the request is
// answered or passed over, and licensing goes on waiting for its own PDU. These are upstream's
// tests of it, on this crate's own settings.
#![cfg(feature = "rdp")]

use std::borrow::Cow;
use std::sync::Arc;

use ironrdp_connector::{
    ClientConnector, ClientConnectorState, Config, ConnectorResult, Credentials, DesktopSize, LicenseCache,
    LicenseExchangeSequence, LicenseExchangeState, MonotonicInstant, Sequence as _, Written,
};
use ironrdp_pdu::gcc::{ConnectionType, KeyboardType};
use ironrdp_pdu::rdp::capability_sets::{MajorPlatformType, RailSupportLevel};
use ironrdp_pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use ironrdp_pdu::mcs::{McsMessage, SendDataIndication};
use ironrdp_pdu::rdp::autodetect::{AutoDetectReqPdu, AutoDetectRequest, AutoDetectResponse, AutoDetectRspPdu};
use ironrdp_pdu::rdp::headers::{BasicSecurityHeader, BasicSecurityHeaderFlags};
use ironrdp_pdu::rdp::server_license::{
    LicenseErrorCode, LicenseHeader, LicenseInformation, LicensePdu, LicensingErrorMessage, LicensingStateTransition,
    PreambleFlags, PreambleType, PreambleVersion,
};
use ironrdp_pdu::x224::X224;
use ironrdp_pdu::{encode_vec, WriteBuf};

const USER_CHANNEL_ID: u16 = 1002;
const IO_CHANNEL_ID: u16 = 1003;
const MESSAGE_CHANNEL_ID: u16 = 1004;

/// A license cache that holds nothing.
#[derive(Debug)]
struct NoLicense;

impl LicenseCache for NoLicense {
    fn get_license(&self, _license_info: LicenseInformation) -> ConnectorResult<Option<Vec<u8>>> {
        Ok(None)
    }

    fn store_license(&self, _license_info: LicenseInformation) -> ConnectorResult<()> {
        Ok(())
    }
}

/// The settings the app's sessions connect with (src/rdp/mod.rs connector_config, NLA offered and
/// bitmap graphics); the crate is a native library only, so a test of it cannot call that.
fn config() -> Config {
    Config {
        desktop_size: DesktopSize { width: 1024, height: 768 },
        monitor_layout: None,
        desktop_scale_factor: 0,
        desktop_physical_size: None,
        desktop_orientation: None,
        device_scale_factor: None,
        monitor_extended_layout: None,
        relative_mouse_input: false,
        enable_tls: true,
        enable_credssp: true,
        enable_standard_rdp_security: false,
        credentials: Credentials::UsernamePassword { username: "alex".into(), password: "pw".into() },
        domain: None,
        client_build: 0,
        client_name: "zestssh".to_owned(),
        keyboard_type: KeyboardType::IBM_ENHANCED,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0x0409,
        connection_type: ConnectionType::Lan,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: r"C:\Windows\System32\mstscax.dll".to_owned(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        remote_application_mode: false,
        rail_support_level: RailSupportLevel::empty(),
        platform: MajorPlatformType::WINDOWS,
        hardware_id: None,
        request_data: None,
        autologon: true,
        enable_audio_playback: false,
        enable_audio_capture: false,
        performance_flags: PerformanceFlags::default(),
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        compression_type: None,
        enable_server_pointer: true,
        pointer_software_rendering: false,
        multitransport_flags: None,
        support_dyn_vc_gfx_protocol: false,
    }
}

/// A connector of this app's settings that has just entered the licensing exchange, with a
/// negotiated message channel.
fn licensing_exchange_connector() -> ClientConnector {
    let config = config();
    let mut connector = ClientConnector::new(config, "127.0.0.1:12345".parse().unwrap());
    connector.state = ClientConnectorState::LicensingExchange {
        io_channel_id: IO_CHANNEL_ID,
        user_channel_id: USER_CHANNEL_ID,
        license_exchange: LicenseExchangeSequence::new(
            IO_CHANNEL_ID,
            "test".to_owned(),
            None,
            [0; 4],
            Arc::new(NoLicense),
        ),
    };
    connector.message_channel_id = Some(MESSAGE_CHANNEL_ID);
    connector
}

/// A server-to-client SendDataIndication on `channel_id`.
fn server_send_data_indication(channel_id: u16, user_data: Vec<u8>) -> Vec<u8> {
    let indication = McsMessage::SendDataIndication(SendDataIndication {
        initiator_id: USER_CHANNEL_ID,
        channel_id,
        user_data: Cow::Owned(user_data),
    });
    encode_vec(&X224(indication)).unwrap()
}

fn license_status_valid_client() -> Vec<u8> {
    let license = LicensePdu::LicensingErrorMessage(LicensingErrorMessage {
        license_header: LicenseHeader {
            security_header: BasicSecurityHeader { flags: BasicSecurityHeaderFlags::LICENSE_PKT },
            preamble_message_type: PreambleType::ErrorAlert,
            preamble_flags: PreambleFlags::empty(),
            preamble_version: PreambleVersion::V3,
            preamble_message_size: 0x10,
        },
        error_code: LicenseErrorCode::StatusValidClient,
        state_transition: LicensingStateTransition::NoTransition,
        error_info: Vec::new(),
    });
    server_send_data_indication(IO_CHANNEL_ID, encode_vec(&license).unwrap())
}

#[test]
fn licensing_answers_an_autodetect_request_and_keeps_waiting() {
    let mut connector = licensing_exchange_connector();
    let mut output = WriteBuf::new();
    let request = AutoDetectReqPdu::new(AutoDetectRequest::rtt_connect_time(0x0001));
    let written = connector
        .step(&server_send_data_indication(MESSAGE_CHANNEL_ID, encode_vec(&request).unwrap()), None, &mut output)
        .expect("an Auto-Detect Request during licensing does not end the connection");
    assert!(written.size().is_some(), "the request is answered");

    let X224(McsMessage::SendDataRequest(sent)) = ironrdp_pdu::decode(output.filled()).unwrap() else {
        panic!("expected a SendDataRequest in the response frame");
    };
    assert_eq!(sent.channel_id, MESSAGE_CHANNEL_ID, "the answer goes out on the message channel");
    let response = ironrdp_pdu::decode::<AutoDetectRspPdu>(&sent.user_data).unwrap();
    assert_eq!(response.response, AutoDetectResponse::RttResponse { sequence_number: 0x0001 });
    assert!(
        matches!(
            &connector.state,
            ClientConnectorState::LicensingExchange { license_exchange, .. }
                if matches!(license_exchange.state, LicenseExchangeState::NewLicenseRequest)
        ),
        "licensing goes on waiting for its PDU, where it was"
    );

    // The licensing PDU that follows is handled as before.
    output.clear();
    connector.step(&license_status_valid_client(), None, &mut output).unwrap();
    assert!(
        matches!(connector.state, ClientConnectorState::MultitransportBootstrapping { .. }),
        "the licensing PDU completes the exchange"
    );
}

/// The PDU an RDS host mixed into licensing, byte for byte (the trace in IronRDP issue #1629): a
/// Bandwidth Measure Start of the reliable UDP kind, which needs no answer but is no licensing PDU.
#[test]
fn licensing_passes_over_the_request_an_rds_host_mixes_in() {
    const SERVER_PDU: [u8; 10] = [
        0x00, 0x10, // flags: SEC_AUTODETECT_REQ
        0x00, 0x00, // flagsHi
        0x06, // headerLength
        0x00, // headerTypeId: TYPE_ID_AUTODETECT_REQUEST
        0x00, 0x00, // sequenceNumber
        0x14, 0x00, // requestType: Bandwidth Measure Start (reliable UDP)
    ];
    let mut connector = licensing_exchange_connector();
    let mut output = WriteBuf::new();
    let written = connector
        .step(
            &server_send_data_indication(MESSAGE_CHANNEL_ID, SERVER_PDU.to_vec()),
            Some(MonotonicInstant::from_millis(1_000)),
            &mut output,
        )
        .expect("the RDS host's request does not end the connection");
    assert_eq!(written, Written::Nothing);
    assert!(matches!(connector.state, ClientConnectorState::LicensingExchange { .. }));
}

#[test]
fn licensing_passes_over_other_message_channel_pdus() {
    let mut connector = licensing_exchange_connector();
    let mut output = WriteBuf::new();
    for flags in [BasicSecurityHeaderFlags::HEARTBEAT, BasicSecurityHeaderFlags::AUTODETECT_REQ] {
        // A heartbeat, and an Auto-Detect Request header with nothing after it.
        let user_data = encode_vec(&BasicSecurityHeader { flags }).unwrap();
        let written = connector
            .step(&server_send_data_indication(MESSAGE_CHANNEL_ID, user_data), None, &mut output)
            .expect("a message-channel PDU during licensing does not end the connection");
        assert_eq!(written, Written::Nothing);
        assert!(matches!(connector.state, ClientConnectorState::LicensingExchange { .. }));
    }
}
