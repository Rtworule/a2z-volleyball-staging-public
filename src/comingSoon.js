const contactEmail = "support@atozvolleyball.com";

document.querySelector("#app").innerHTML = `
  <main class="coming-soon-shell" aria-labelledby="page-title">
    <section class="coming-soon-hero">
      <header class="site-header">
        <a class="brand-lockup" href="mailto:${contactEmail}" aria-label="Email A to Z Volleyball Center">
          <img
            class="brand-logo"
            src="/brand-logo-v2.webp"
            alt="A to Z Volleyball Center logo"
          >
          <span class="brand-name">A to Z Volleyball Center</span>
        </a>
      </header>

      <div class="hero-copy">
        <p class="launch-status" aria-label="Coming Soon in October">
          <span>Coming Soon</span>
          <strong>in October</strong>
        </p>
        <p class="eyebrow">Northern Virginia</p>
        <h1 id="page-title">Where volleyball finds its home.</h1>
        <p class="summary">
          A to Z Volleyball Center is coming soon with dedicated indoor courts,
          focused training, and space for teams to grow together.
        </p>

        <a class="contact-link" href="mailto:${contactEmail}">
          <span class="contact-label">Contact us</span>
          <span class="contact-email">${contactEmail}</span>
        </a>
      </div>

      <footer class="hero-footer" aria-label="Facility preview">
        <span>Indoor courts</span>
        <span>Training</span>
        <span>Team play</span>
      </footer>
    </section>
  </main>
`;
