const form = document.querySelector('#waitlist');
const feedback = document.querySelector('#waitlist-feedback');
const button = form.querySelector('button');

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (button.disabled) return;

  button.disabled = true;
  feedback.textContent = 'Saving your email…';
  try {
    const response = await fetch(form.action, {
      method: 'POST',
      headers: { Accept: 'application/json' },
      body: new URLSearchParams(new FormData(form)),
    });
    const { outcome } = await response.json();
    if (response.ok && outcome === 'joined') {
      form.reset();
      feedback.textContent = 'You’re on the list. We’ll email you when RecordPOV is live.';
    } else if (outcome === 'invalid') {
      feedback.textContent = 'Enter a valid email address and try again.';
    } else {
      feedback.textContent = 'We couldn’t save your email. Try again in a moment.';
    }
  } catch {
    feedback.textContent = 'We couldn’t save your email. Try again in a moment.';
  } finally {
    button.disabled = false;
  }
});
