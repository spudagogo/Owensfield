export function PlaceholderPage(props: { title: string; note?: string }) {
  return (
    <section>
      <h1>{props.title}</h1>
      <p>This is a placeholder page. No features are implemented yet.</p>
      {props.note ? <p>{props.note}</p> : null}
    </section>
  );
}

