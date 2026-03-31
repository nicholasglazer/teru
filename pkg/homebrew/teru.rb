class Teru < Formula
  desc "AI-first terminal emulator, multiplexer, and tiling manager"
  homepage "https://github.com/nicholasglazer/teru"
  url "https://github.com/nicholasglazer/teru/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  depends_on "zig" => :build

  on_linux do
    depends_on "libxcb"
    depends_on "libxkbcommon"
    depends_on "wayland"
  end

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe"
    bin.install "zig-out/bin/teru"
  end

  test do
    assert_match "teru", shell_output("#{bin}/teru --version")
  end
end
