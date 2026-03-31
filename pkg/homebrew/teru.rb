class Teru < Formula
  desc "AI-first terminal emulator, multiplexer, and tiling manager"
  homepage "https://github.com/nicholasglazer/teru"
  url "https://github.com/nicholasglazer/teru/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "ad30c4c7f087e8d6ace38a1ff0fde01383db6de1e171322824cd21e5aa9a2dea"
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
