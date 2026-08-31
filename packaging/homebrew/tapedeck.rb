class Tapedeck < Formula
  desc "Record your LLM calls once, replay them free"
  homepage "https://github.com/tunardev/tapedeck"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/tunardev/tapedeck/releases/download/v#{version}/tapedeck-aarch64-macos.tar.gz"
      sha256 "REPLACE_WITH_RELEASE_SHA256"
    end
    on_intel do
      url "https://github.com/tunardev/tapedeck/releases/download/v#{version}/tapedeck-x86_64-macos.tar.gz"
      sha256 "REPLACE_WITH_RELEASE_SHA256"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/tunardev/tapedeck/releases/download/v#{version}/tapedeck-aarch64-linux-musl.tar.gz"
      sha256 "REPLACE_WITH_RELEASE_SHA256"
    end
    on_intel do
      url "https://github.com/tunardev/tapedeck/releases/download/v#{version}/tapedeck-x86_64-linux-musl.tar.gz"
      sha256 "REPLACE_WITH_RELEASE_SHA256"
    end
  end

  def install
    bin.install "tapedeck"
  end

  test do
    assert_match "tapedeck #{version}", shell_output("#{bin}/tapedeck --version")
  end
end
