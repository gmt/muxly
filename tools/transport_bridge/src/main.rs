use anyhow::{anyhow, bail, Context, Result};
use serde::Serialize;
use std::collections::HashMap;
use std::env;
use std::net::{SocketAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use tokio::fs;
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, BufStream,
};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::time::{timeout, Duration};
use wtransport::tls::Sha256Digest;
use wtransport::{ClientConfig, Endpoint, Identity, ServerConfig, VarInt};

#[derive(Debug)]
enum Command {
    HttpClient(HttpClientArgs),
    HttpServer(HttpServerArgs),
    H3wtClient(H3wtClientArgs),
    H3wtServer(H3wtServerArgs),
}

#[derive(Debug)]
struct HttpClientArgs {
    host: String,
    port: u16,
    path: String,
}

#[derive(Debug)]
struct HttpServerArgs {
    listen_host: String,
    listen_port: u16,
    path: String,
    upstream_unix: PathBuf,
    ready_file: PathBuf,
}

#[derive(Debug)]
struct H3wtClientArgs {
    host: String,
    port: u16,
    path: String,
    sha256: Option<String>,
}

#[derive(Debug)]
struct H3wtServerArgs {
    listen_host: String,
    listen_port: u16,
    path: String,
    upstream_unix: PathBuf,
    ready_file: PathBuf,
}

#[derive(Serialize)]
struct ReadyFile<'a> {
    host: &'a str,
    port: u16,
    path: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    sha256: Option<&'a str>,
}

struct HttpRequest {
    path: String,
    body: Vec<u8>,
}

#[tokio::main]
async fn main() {
    if let Err(err) = real_main().await {
        eprintln!("{err:?}");
        std::process::exit(1);
    }
}

async fn real_main() -> Result<()> {
    match parse_args()? {
        Command::HttpClient(args) => run_http_client(args).await,
        Command::HttpServer(args) => run_http_server(args).await,
        Command::H3wtClient(args) => run_h3wt_client(args).await,
        Command::H3wtServer(args) => run_h3wt_server(args).await,
    }
}

fn parse_args() -> Result<Command> {
    let mut args = env::args().skip(1);
    let subcommand = args.next().ok_or_else(|| anyhow!("missing subcommand"))?;
    let mut values: HashMap<String, String> = HashMap::new();

    while let Some(flag) = args.next() {
        if !flag.starts_with("--") {
            bail!("unexpected argument: {flag}");
        }
        let key = flag.trim_start_matches("--").to_string();
        if key == "allow-insecure" {
            values.insert(key, "true".to_string());
            continue;
        }
        let value = args
            .next()
            .ok_or_else(|| anyhow!("missing value for --{key}"))?;
        values.insert(key, value);
    }

    match subcommand.as_str() {
        "http-client" => Ok(Command::HttpClient(HttpClientArgs {
            host: required(&values, "host")?,
            port: required(&values, "port")?
                .parse()
                .context("invalid --port")?,
            path: required(&values, "path")?,
        })),
        "http-server" => Ok(Command::HttpServer(HttpServerArgs {
            listen_host: required(&values, "listen-host")?,
            listen_port: required(&values, "listen-port")?
                .parse()
                .context("invalid --listen-port")?,
            path: required(&values, "path")?,
            upstream_unix: PathBuf::from(required(&values, "upstream-unix")?),
            ready_file: PathBuf::from(required(&values, "ready-file")?),
        })),
        "h3wt-client" => Ok(Command::H3wtClient(H3wtClientArgs {
            host: required(&values, "host")?,
            port: required(&values, "port")?
                .parse()
                .context("invalid --port")?,
            path: required(&values, "path")?,
            sha256: values.get("sha256").cloned(),
        })),
        "h3wt-server" => Ok(Command::H3wtServer(H3wtServerArgs {
            listen_host: required(&values, "listen-host")?,
            listen_port: required(&values, "listen-port")?
                .parse()
                .context("invalid --listen-port")?,
            path: required(&values, "path")?,
            upstream_unix: PathBuf::from(required(&values, "upstream-unix")?),
            ready_file: PathBuf::from(required(&values, "ready-file")?),
        })),
        other => bail!("unknown subcommand: {other}"),
    }
}

fn required(values: &HashMap<String, String>, key: &str) -> Result<String> {
    values
        .get(key)
        .cloned()
        .ok_or_else(|| anyhow!("missing --{key}"))
}

async fn run_http_client(args: HttpClientArgs) -> Result<()> {
    let host_header = host_header(&args.host, args.port);
    let stream = TcpStream::connect((args.host.as_str(), args.port))
        .await
        .with_context(|| format!("unable to connect to {}:{}", args.host, args.port))?;
    let mut network = BufStream::new(stream);
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();

    while let Some(request_body) = read_line_message(&mut stdin).await? {
        write_http_request(&mut network, &args.path, &host_header, &request_body).await?;
        network.flush().await?;

        let response_body = read_http_response(&mut network).await?;
        stdout.write_all(&response_body).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }

    Ok(())
}

async fn run_http_server(args: HttpServerArgs) -> Result<()> {
    let listener = TcpListener::bind((args.listen_host.as_str(), args.listen_port))
        .await
        .with_context(|| {
            format!(
                "unable to bind HTTP listener on {}:{}",
                args.listen_host, args.listen_port
            )
        })?;
    let local_addr = listener
        .local_addr()
        .context("missing local HTTP address")?;

    write_ready_file(
        &args.ready_file,
        ReadyFile {
            host: &args.listen_host,
            port: local_addr.port(),
            path: &args.path,
            sha256: None,
        },
    )
    .await?;

    loop {
        let (socket, _) = listener.accept().await?;
        let path = args.path.clone();
        let upstream_unix = args.upstream_unix.clone();
        tokio::spawn(async move {
            let _ = handle_http_connection(socket, upstream_unix, path).await;
        });
    }
}

async fn handle_http_connection(
    socket: TcpStream,
    upstream_unix: PathBuf,
    path: String,
) -> Result<()> {
    let mut client = BufStream::new(socket);

    while let Some(request) = read_http_request(&mut client).await? {
        if request.path != path {
            write_http_error(&mut client, 404, "Not Found").await?;
            client.flush().await?;
            continue;
        }

        let upstream = UnixStream::connect(&upstream_unix).await.with_context(|| {
            format!("unable to connect to upstream {}", upstream_unix.display())
        })?;
        let mut upstream = BufStream::new(upstream);
        upstream.write_all(&request.body).await?;
        upstream.write_all(b"\n").await?;
        upstream.flush().await?;

        let response = read_line_message(&mut upstream)
            .await?
            .ok_or_else(|| anyhow!("upstream closed before sending a response"))?;
        drop(upstream);
        write_http_response(&mut client, &response).await?;
        client.flush().await?;
    }

    Ok(())
}

async fn run_h3wt_client(args: H3wtClientArgs) -> Result<()> {
    let client_config = build_h3wt_client_config(&args.host, args.sha256.as_deref()).await?;
    let endpoint = Endpoint::client(client_config)?;
    let url = format!(
        "https://{}{}{}",
        authority(&args.host, args.port),
        args.path,
        ""
    );
    let connection = timeout(Duration::from_secs(5), endpoint.connect(&url))
        .await
        .context("timed out while connecting WebTransport session")??;
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();

    while let Some(request) = read_line_message(&mut stdin).await? {
        trace(&format!("h3wt client request bytes={}", request.len()));
        let stream = timeout(Duration::from_secs(5), connection.open_bi())
            .await
            .context("timed out while opening WebTransport request stream")??;
        let (mut send_stream, recv_stream) = timeout(Duration::from_secs(5), stream)
            .await
            .context("timed out while awaiting WebTransport request stream readiness")??;

        send_stream.write_all(&request).await?;
        send_stream.write_all(b"\n").await?;
        send_stream.flush().await?;
        send_stream.finish().await?;
        tokio::task::yield_now().await;

        let mut recv_reader = BufReader::new(recv_stream);
        let response = read_line_message(&mut recv_reader)
            .await?
            .ok_or_else(|| anyhow!("missing WebTransport response body"))?;
        trace(&format!("h3wt client response bytes={}", response.len()));
        stdout.write_all(&response).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }

    connection.close(VarInt::from_u32(0), b"muxly client done");
    let _ = timeout(Duration::from_secs(1), connection.closed()).await;

    Ok(())
}

async fn run_h3wt_server(args: H3wtServerArgs) -> Result<()> {
    let identity = load_or_create_identity(&args.listen_host).await?;
    let sha256 = identity.certificate_chain().as_slice()[0]
        .hash()
        .to_string();
    let bind_addr = resolve_socket_addr(&args.listen_host, args.listen_port)?;
    let config = ServerConfig::builder()
        .with_bind_address(bind_addr)
        .with_identity(identity)
        .build();
    let endpoint = Endpoint::server(config)?;
    let local_addr = endpoint
        .local_addr()
        .context("missing local WebTransport address")?;

    write_ready_file(
        &args.ready_file,
        ReadyFile {
            host: &args.listen_host,
            port: local_addr.port(),
            path: &args.path,
            sha256: Some(&sha256),
        },
    )
    .await?;

    loop {
        let incoming = endpoint.accept().await;
        let expected_path = args.path.clone();
        let upstream_unix = args.upstream_unix.clone();
        tokio::spawn(async move {
            let _ = handle_h3wt_session(incoming, expected_path, upstream_unix).await;
        });
    }
}

async fn handle_h3wt_session(
    incoming: wtransport::endpoint::IncomingSession,
    expected_path: String,
    upstream_unix: PathBuf,
) -> Result<()> {
    let session_request = incoming.await?;
    if session_request.path() != expected_path {
        bail!("unexpected WebTransport path: {}", session_request.path());
    }

    let connection = session_request.accept().await?;

    loop {
        let mut bi_stream = connection.accept_bi().await?;
        let mut request_reader = BufReader::new(bi_stream.1);
        let request = read_line_message(&mut request_reader)
            .await?
            .ok_or_else(|| anyhow!("missing WebTransport request body"))?;
        trace(&format!("h3wt server request bytes={}", request.len()));
        tokio::task::yield_now().await;

        let upstream = UnixStream::connect(&upstream_unix).await.with_context(|| {
            format!("unable to connect to upstream {}", upstream_unix.display())
        })?;
        let mut upstream = BufStream::new(upstream);
        upstream.write_all(&request).await?;
        upstream.write_all(b"\n").await?;
        upstream.flush().await?;

        let response = read_line_message(&mut upstream)
            .await?
            .ok_or_else(|| anyhow!("upstream closed before sending a response"))?;
        trace(&format!("h3wt server response bytes={}", response.len()));
        drop(upstream);
        tokio::task::yield_now().await;
        bi_stream.0.write_all(&response).await?;
        bi_stream.0.write_all(b"\n").await?;
        bi_stream.0.flush().await?;
        bi_stream.0.finish().await?;
        tokio::task::yield_now().await;
    }
}

async fn build_h3wt_client_config(_host: &str, sha256: Option<&str>) -> Result<ClientConfig> {
    let builder = ClientConfig::builder().with_bind_default();

    if let Some(hash_text) = sha256 {
        let digest: Sha256Digest = hash_text.parse().context("invalid --sha256 hash")?;
        return Ok(builder.with_server_certificate_hashes([digest]).build());
    }

    Ok(builder.with_native_certs().build())
}

async fn load_or_create_identity(listen_host: &str) -> Result<Identity> {
    if let (Ok(cert_path), Ok(key_path)) = (env::var("MUXLY_H3WT_CERT"), env::var("MUXLY_H3WT_KEY"))
    {
        return Identity::load_pemfiles(cert_path, key_path)
            .await
            .context("unable to load MUXLY_H3WT_CERT/MUXLY_H3WT_KEY");
    }

    let (cert_path, key_path) = identity_paths()?;
    if cert_path.exists() && key_path.exists() {
        return Identity::load_pemfiles(&cert_path, &key_path)
            .await
            .with_context(|| format!("unable to load {}", cert_path.display()));
    }

    if let Some(parent) = cert_path.parent() {
        fs::create_dir_all(parent).await?;
    }
    if let Some(parent) = key_path.parent() {
        fs::create_dir_all(parent).await?;
    }

    let mut names = vec![
        "localhost".to_string(),
        "127.0.0.1".to_string(),
        "::1".to_string(),
    ];
    if !listen_host.is_empty()
        && listen_host != "0.0.0.0"
        && listen_host != "::"
        && !names.iter().any(|value| value == listen_host)
    {
        names.push(listen_host.to_string());
    }

    let identity = Identity::self_signed(names)?;
    identity
        .certificate_chain()
        .store_pemfile(&cert_path)
        .await?;
    identity
        .private_key()
        .store_secret_pemfile(&key_path)
        .await?;
    Ok(identity)
}

fn identity_paths() -> Result<(PathBuf, PathBuf)> {
    if let Ok(dir) = env::var("MUXLY_H3WT_IDENTITY_DIR") {
        let base = PathBuf::from(dir);
        return Ok((base.join("cert.pem"), base.join("key.pem")));
    }

    if let Ok(state_home) = env::var("XDG_STATE_HOME") {
        let base = PathBuf::from(state_home).join("muxly");
        return Ok((base.join("h3wt-cert.pem"), base.join("h3wt-key.pem")));
    }

    let home = env::var("HOME").context("HOME is not set")?;
    let base = PathBuf::from(home).join(".local/state/muxly");
    Ok((base.join("h3wt-cert.pem"), base.join("h3wt-key.pem")))
}

async fn write_ready_file(path: &Path, ready: ReadyFile<'_>) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await?;
    }
    let bytes = serde_json::to_vec_pretty(&ready)?;
    fs::write(path, bytes).await?;
    Ok(())
}

fn resolve_socket_addr(host: &str, port: u16) -> Result<SocketAddr> {
    (host, port)
        .to_socket_addrs()
        .context("unable to resolve socket address")?
        .next()
        .ok_or_else(|| anyhow!("no resolved socket address"))
}

fn authority(host: &str, port: u16) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn host_header(host: &str, port: u16) -> String {
    authority(host, port)
}

async fn read_line_message<R>(reader: &mut R) -> Result<Option<Vec<u8>>>
where
    R: AsyncBufRead + Unpin,
{
    let mut line = Vec::new();
    let bytes_read = reader.read_until(b'\n', &mut line).await?;
    if bytes_read == 0 {
        return Ok(None);
    }
    if line.last().copied() == Some(b'\n') {
        line.pop();
    }
    if line.last().copied() == Some(b'\r') {
        line.pop();
    }
    Ok(Some(line))
}

async fn read_http_request<R>(reader: &mut R) -> Result<Option<HttpRequest>>
where
    R: AsyncBufRead + Unpin,
{
    let mut request_line = String::new();
    loop {
        request_line.clear();
        let bytes_read = reader.read_line(&mut request_line).await?;
        if bytes_read == 0 {
            return Ok(None);
        }
        if request_line == "\r\n" {
            continue;
        }
        break;
    }

    let mut parts = request_line.trim_end().split_whitespace();
    let method = parts.next().ok_or_else(|| anyhow!("missing HTTP method"))?;
    let path = parts.next().ok_or_else(|| anyhow!("missing HTTP path"))?;
    let version = parts
        .next()
        .ok_or_else(|| anyhow!("missing HTTP version"))?;
    if method != "POST" || !version.starts_with("HTTP/1.1") {
        bail!("unsupported HTTP request line: {request_line}");
    }

    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let bytes_read = reader.read_line(&mut line).await?;
        if bytes_read == 0 {
            bail!("unexpected EOF while reading HTTP headers");
        }
        if line == "\r\n" {
            break;
        }

        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(value.trim().parse().context("invalid Content-Length")?);
            }
        }
    }

    let content_length = content_length.ok_or_else(|| anyhow!("missing Content-Length"))?;
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body).await?;
    Ok(Some(HttpRequest {
        path: path.to_string(),
        body,
    }))
}

async fn read_http_response<R>(reader: &mut R) -> Result<Vec<u8>>
where
    R: AsyncBufRead + Unpin,
{
    let mut status_line = String::new();
    let bytes_read = reader.read_line(&mut status_line).await?;
    if bytes_read == 0 {
        bail!("unexpected EOF while reading HTTP response");
    }
    if !status_line.starts_with("HTTP/1.1 200") {
        bail!("unexpected HTTP status line: {}", status_line.trim_end());
    }

    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let bytes_read = reader.read_line(&mut line).await?;
        if bytes_read == 0 {
            bail!("unexpected EOF while reading HTTP response headers");
        }
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(value.trim().parse().context("invalid Content-Length")?);
            }
        }
    }

    let content_length = content_length.ok_or_else(|| anyhow!("missing Content-Length"))?;
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body).await?;
    Ok(body)
}

async fn write_http_request<W>(writer: &mut W, path: &str, host: &str, body: &[u8]) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    writer
        .write_all(
            format!(
                "POST {path} HTTP/1.1\r\nHost: {host}\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                body.len()
            )
            .as_bytes(),
        )
        .await?;
    writer.write_all(body).await?;
    Ok(())
}

async fn write_http_response<W>(writer: &mut W, body: &[u8]) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    writer
        .write_all(
            format!(
                "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                body.len()
            )
            .as_bytes(),
        )
        .await?;
    writer.write_all(body).await?;
    Ok(())
}

async fn write_http_error<W>(writer: &mut W, status: u16, message: &str) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    writer
        .write_all(
            format!(
                "HTTP/1.1 {status} {message}\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n"
            )
            .as_bytes(),
        )
        .await?;
    Ok(())
}

fn trace(message: &str) {
    if env::var_os("MUXLY_TRANSPORT_BRIDGE_TRACE").is_some() {
        eprintln!("[muxly-transport-bridge] {message}");
    }
}
