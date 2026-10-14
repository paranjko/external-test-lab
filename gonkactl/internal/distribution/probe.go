package distribution

func ReadbackOK(install, manifest, asset int) bool {
	return install == 200 && manifest == 200 && asset == 200
}
