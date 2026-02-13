class HungDetect < Formula
  desc "Detect Not Responding macOS GUI apps via Activity Monitor private signal"
  homepage "https://github.com/fjh658/hung_detect"
  license "Apache-2.0"
  version "0.2.0"

  tap_root = Pathname.new(__dir__).parent
  artifact = tap_root/"dist"/"hung-detect-0.2.0-macos-universal.tar.gz"
  url "file://#{artifact}"
  sha256 "734ce97861660cf078dfb9a317c72643a0a16fcf3d08071dddb388d8c4812f52"

  depends_on :macos

  def install
    bin.install "hung_detect"
    bin.install "hung_diagnosis"
  end

  test do
    assert_match "hung_detect", shell_output("#{bin}/hung_detect --help")
  end
end
