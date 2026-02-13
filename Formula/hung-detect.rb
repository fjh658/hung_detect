class HungDetect < Formula
  desc "Detect Not Responding macOS GUI apps via Activity Monitor private signal"
  homepage "https://github.com/fjh658/hung_detect"
  license "Apache-2.0"
  version "0.3.0"

  tap_root = Pathname.new(__dir__).parent
  artifact = tap_root/"dist"/"hung-detect-0.3.0-macos-universal.tar.gz"
  url "file://#{artifact}"
  sha256 "9cdfeb6c8573f732748171ddb30d0a5d71317bc424189820a7ccf886b80e9120"

  depends_on :macos

  def install
    bin.install "hung_detect"
  end

  test do
    assert_match "hung_detect", shell_output("#{bin}/hung_detect --help")
  end
end
